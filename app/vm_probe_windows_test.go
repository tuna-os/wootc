//go:build windows

package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// Explicit fixture-only entry point. Production has no environment-selected
// runtime, public key, or TCG fallback. Corral supplies its isolated signed tree.
func TestVMExecutionProbeRealQEMU(t *testing.T) {
	runtimeDir := os.Getenv("WOOTC_TEST_QEMU_RUNTIME")
	if runtimeDir == "" {
		t.Skip("requires isolated signed QEMU fixture")
	}
	if err := verifyVMRuntime(runtimeDir, os.Getenv("WOOTC_TEST_ARTIFACT_PUBLIC_KEY")); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	disk := filepath.Join(dir, "probe.raw")
	serial := filepath.Join(dir, "serial.log")
	if err := os.WriteFile(disk, vmProbeBootSector, 0600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(filepath.Join(runtimeDir, "qemu-system-x86_64.exe"), "-machine", "q35", "-accel", "tcg", "-cpu", "max", "-smp", "1", "-m", "128", "-display", "none", "-monitor", "none", "-serial", "file:"+serial, "-drive", "file="+qemuEscape(disk)+",format=raw,if=floppy,readonly=on", "-boot", "a")
	cmd.Dir = runtimeDir
	cmd.Env = vmProcessEnvironment(runtimeDir, dir)
	cmd.SysProcAttr = vmProcessAttributes()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	start := time.Now()
	result := runVMExecutionProbe(ctx, cmd, serial, ownVMProcess)
	t.Logf("Actual Windows QEMU q35/TCG execution: %s in %s", result.Status, time.Since(start))
	if result.Status != "passed" {
		t.Fatalf("probe: %+v", result)
	}
}
