package main

import (
	"context"
	_ "embed"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"
)

//go:embed vmprobe/serial-boot.img
var vmProbeBootSector []byte

const vmProbeMarker = "WOOTC_WHPX_BOOTSECTOR_EXECUTED"

type vmExecutionProbeResult struct {
	Status      string
	Detail      string
	Accelerator string
}

// Read guest serial from a newly created file, never process liveness or an
// old diagnostic log. The image is a read-only 512-byte program with no OS or
// user data. Terminating this probe cannot interrupt a writable filesystem.
func runVMExecutionProbe(ctx context.Context, cmd *exec.Cmd, serialPath string, own func(*exec.Cmd) (io.Closer, error)) vmExecutionProbeResult {
	result := vmExecutionProbeResult{Status: "failed"}
	serial, err := os.OpenFile(serialPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		result.Detail = "Could not create a private VM execution probe."
		return result
	}
	serial.Close()
	if err = cmd.Start(); err != nil {
		result.Detail = fmt.Sprintf("Could not start the VM execution probe: %v", err)
		return result
	}
	job, err := own(cmd)
	if err != nil {
		cmd.Process.Kill()
		cmd.Wait()
		result.Detail = "Could not own the VM execution probe."
		return result
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	defer func() { _ = cmd.Process.Kill(); _ = job.Close(); <-done }()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			result.Status = "timed_out"
			result.Detail = "The guest execution check did not finish within its time limit. A slow or busy PC can cause this; it does not prove this PC is unsupported. Close other apps and try again."
			return result
		case err := <-done:
			done <- err // leave the single completion for the cleanup barrier
			result.Detail = "The VM execution probe exited before guest code reported success."
			return result
		case <-ticker.C:
			data, err := readLocalMetadata(serialPath, 8192)
			if err == nil && strings.Contains(string(data), vmProbeMarker) {
				result.Status = "passed"
				return result
			}
		}
	}
}
