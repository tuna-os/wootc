//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

// VM modes (SPEC §6.2): boot the installed root.disk directly in a QEMU
// window on Windows using WHPX acceleration — the user sees their Linux
// system without rebooting. Same disk, same state as the dual-boot path.
//
// QEMU-for-Windows + edk2 firmware are bundled under C:\wootc\qemu\ by the
// release. This code is the launcher + capability probe.

// VMCapability tells the GUI whether "Boot in VM" can run and why not.
type VMCapability struct {
	Available bool   `json:"available"`
	Reason    string `json:"reason"`
	DiskPath  string `json:"diskPath"`
}

func qemuDir() string  { return filepath.Join(wootcDir(), "qemu") }
func qemuExe() string  { return filepath.Join(qemuDir(), "qemu-system-x86_64.exe") }
func edk2Code() string { return filepath.Join(qemuDir(), "edk2-x86_64-code.fd") }

// GetVMCapability reports whether the installed disk can be booted in a VM.
func (a *App) GetVMCapability() VMCapability {
	info := getUninstallInfo() // reuses root.disk discovery
	if !info.Found {
		return VMCapability{Available: false, Reason: "No installed TunaOS disk was found."}
	}
	if _, err := os.Stat(qemuExe()); err != nil {
		return VMCapability{Available: false, DiskPath: info.DiskPath,
			Reason: "The VM viewer isn't installed. Reinstall wootc with the VM option to enable it."}
	}
	if !whpxAvailable() {
		return VMCapability{Available: false, DiskPath: info.DiskPath,
			Reason: "Windows Hypervisor Platform is turned off. Enable it in " +
				"'Turn Windows features on or off' to run Linux in a window."}
	}
	return VMCapability{Available: true, DiskPath: info.DiskPath}
}

// BootInVM launches QEMU on the installed root.disk in its own window
// (SPEC §6.2). Changes made in the VM persist — it's the same filesystem
// as the dual-boot install. Returns once QEMU has started (non-blocking).
func (a *App) BootInVM() error {
	cap := a.GetVMCapability()
	if !cap.Available {
		return fmt.Errorf("%s", cap.Reason)
	}
	args := []string{
		"-accel", "whpx",
		"-m", "4G", "-smp", "4",
		"-machine", "q35",
		"-drive", "file=" + cap.DiskPath + ",format=vhdx,if=virtio",
		"-drive", "if=pflash,format=raw,readonly=on,file=" + edk2Code(),
		"-nic", "user,hostfwd=tcp::2222-:22",
		"-display", "gtk",
		"-name", "TunaOS (VM)",
	}
	cmd := exec.Command(qemuExe(), args...)
	cmd.Dir = qemuDir()
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: false}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("launching QEMU: %w", err)
	}
	// Detach: the VM window outlives this call.
	go func() { _ = cmd.Wait() }()
	return nil
}

// whpxAvailable checks whether the Windows Hypervisor Platform feature is
// enabled (required for QEMU's whpx accelerator).
func whpxAvailable() bool {
	out, err := runPowerShellOutput(
		`(Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction SilentlyContinue).State`)
	if err != nil {
		return false
	}
	return strings.TrimSpace(out) == "Enabled"
}
