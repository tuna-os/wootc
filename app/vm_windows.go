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
	Available   bool   `json:"available"`
	Reason      string `json:"reason"`
	DiskPath    string `json:"diskPath"`
	Accelerator string `json:"accelerator"`
	QEMUPath    string `json:"qemuPath"`
	Bundled     bool   `json:"bundled"`
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
	qemuPath, bundled := findQEMU()
	if qemuPath == "" {
		return VMCapability{Available: false, DiskPath: info.DiskPath,
			Reason: "QEMU isn't installed. Install QEMU for Windows or reinstall wootc with the VM viewer."}
	}
	if _, err := os.Stat(edk2Code()); err != nil {
		return VMCapability{Available: false, DiskPath: info.DiskPath,
			QEMUPath: qemuPath, Bundled: bundled,
			Reason: "The VM firmware is missing. Reinstall wootc with the VM viewer."}
	}
	accelerator := availableAccelerator()
	if accelerator == "" {
		return VMCapability{Available: false, DiskPath: info.DiskPath,
			QEMUPath: qemuPath, Bundled: bundled,
			Reason: "No supported VM accelerator is available. Enable Windows Hypervisor Platform in 'Turn Windows features on or off'."}
	}
	return VMCapability{Available: true, DiskPath: info.DiskPath, Accelerator: accelerator, QEMUPath: qemuPath, Bundled: bundled}
}

func findQEMU() (string, bool) {
	if _, err := os.Stat(qemuExe()); err == nil {
		return qemuExe(), true
	}
	path, err := exec.LookPath("qemu-system-x86_64.exe")
	if err != nil {
		return "", false
	}
	return path, false
}

func availableAccelerator() string {
	if whpxAvailable() {
		return "whpx"
	}
	if haxmAvailable() {
		return "hax"
	}
	return ""
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
		"-accel", cap.Accelerator,
		"-m", "4G", "-smp", "4",
		"-machine", "q35",
		"-drive", "file=" + cap.DiskPath + ",format=vhdx,if=virtio",
		"-drive", "if=pflash,format=raw,readonly=on,file=" + edk2Code(),
		"-nic", "user,hostfwd=tcp::2222-:22",
		"-display", "gtk",
		"-name", "TunaOS (VM)",
	}
	cmd := exec.Command(cap.QEMUPath, args...)
	cmd.Dir = filepath.Dir(cap.QEMUPath)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: false}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("launching QEMU: %w", err)
	}
	// Detach: the VM window outlives this call.
	go func() { _ = cmd.Wait() }()
	return nil
}

func haxmAvailable() bool {
	out, err := runPowerShellOutput(`(Get-Service -Name intelhaxm -ErrorAction SilentlyContinue).Status`)
	return err == nil && strings.TrimSpace(out) == "Running"
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
