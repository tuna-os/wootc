//go:build windows

package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

func (a *App) probeVMRuntime(cap VMCapability) VMCapability {
	a.vmProbeMu.Lock()
	defer a.vmProbeMu.Unlock()
	manifest, err := os.ReadFile(filepath.Join(qemuDir(), "SHA256SUMS"))
	if err != nil {
		cap.Available = false
		cap.Reason = "The runtime manifest disappeared before the execution check."
		return cap
	}
	key := fmt.Sprintf("%s:%x", cap.QEMUPath, sha256.Sum256(manifest))
	result := a.vmProbeResult
	if a.vmProbeKey != key || time.Since(a.vmProbeAt) > time.Minute {
		result = a.executeVMProbe(cap)
		a.vmProbeKey = key
		a.vmProbeResult = result
		a.vmProbeAt = time.Now()
	}
	cap.ProbeStatus = result.Status
	cap.Available = result.Status == "passed"
	cap.Reason = result.Detail
	if cap.Available {
		cap.Accelerator = result.Accelerator
	}
	return cap
}

func (a *App) executeVMProbe(cap VMCapability) vmExecutionProbeResult {
	failed := vmExecutionProbeResult{Status: "failed", Detail: "Could not prepare the private VM execution check."}
	if err := os.MkdirAll(previewDir(), 0700); err != nil {
		return failed
	}
	dir, err := os.MkdirTemp(previewDir(), ".probe-")
	if err != nil {
		return failed
	}
	defer os.RemoveAll(dir)
	disk := filepath.Join(dir, "probe.raw")
	if err := os.WriteFile(disk, vmProbeBootSector, 0600); err != nil {
		return failed
	}
	serial := filepath.Join(dir, "serial.log")
	accelerator := "whpx,kernel-irqchip=off"
	cmd := exec.Command(cap.QEMUPath, "-machine", "q35", "-accel", accelerator, "-cpu", "max", "-smp", "1", "-m", "128", "-display", "none", "-monitor", "none", "-serial", "file:"+serial, "-drive", "file="+qemuEscape(disk)+",format=raw,if=floppy,readonly=on", "-boot", "a")
	cmd.Dir = qemuDir()
	cmd.Env = vmProcessEnvironment(qemuDir(), dir)
	cmd.SysProcAttr = vmProcessAttributes()
	stderr, err := os.OpenFile(filepath.Join(dir, "stderr.log"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return failed
	}
	defer stderr.Close()
	cmd.Stderr = stderr
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	result := runVMExecutionProbe(ctx, cmd, serial, ownVMProcess)
	result.Accelerator = accelerator
	return result
}
