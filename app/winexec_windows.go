//go:build windows

package main

import (
	"os/exec"
	"strings"
	"syscall"
)

// ── Helpers ───────────────────────────────────────────────────────────────────

func runCmd(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func runPowerShell(script string) error {
	_, err := runPowerShellOutput(script)
	return err
}

func runPowerShellOutput(script string) (string, error) {
	return runCmd("powershell", "-NoProfile", "-NonInteractive",
		"-ExecutionPolicy", "Bypass", "-Command", script)
}

func restrictFileACL(path string) error {
	// icacls: grant only SYSTEM and Administrators, remove all others
	_, err := runCmd("icacls", path,
		"/inheritance:r",
		"/grant:r", `NT AUTHORITY\SYSTEM:(R,W)`,
		"/grant:r", `BUILTIN\Administrators:(R,W)`,
	)
	return err
}

// wootcDir returns the Windows installation directory.
// storageDrive is the drive letter (no colon) where root.disk + vault
// live; empty means C:. Set from InstallConfig.StorageDrive so BitLocker
// installs can place them on an unencrypted volume (SPEC §3.5).
var storageDrive = ""

func setStorageDrive(letter string) {
	storageDrive = strings.TrimSuffix(strings.ToUpper(strings.TrimSpace(letter)), ":")
}

func wootcDir() string {
	d := storageDrive
	if d == "" {
		d = "C"
	}
	return d + `:\wootc`
}
