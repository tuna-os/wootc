//go:build windows

package main

import (
	"os"
	"strconv"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// ── Firmware, platform and power probes ───────────────────────────────────────

func isAdmin() bool {
	_, err := os.Open(`\\.\PHYSICALDRIVE0`)
	return err == nil
}

func isUEFI() bool {
	// GetFirmwareType is available on Windows 8+
	kernel32 := windows.NewLazySystemDLL("kernel32.dll")
	proc := kernel32.NewProc("GetFirmwareType")
	if proc.Find() != nil {
		return false
	}
	var ft uint32
	r, _, _ := proc.Call(uintptr(unsafe.Pointer(&ft)))
	// FirmwareTypeUefi = 2
	return r != 0 && ft == 2
}

func secureBootEnabled() bool {
	on, _ := secureBootState()
	return on
}

func secureBootState() (bool, bool) {
	out, err := runCmd("powershell", "-NoProfile", "-NonInteractive",
		"-Command", "try { if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'on' } else { 'off' } } catch { 'unknown' }")
	if err != nil {
		return false, false
	}
	switch strings.TrimSpace(out) {
	case "on":
		return true, true
	case "off":
		return false, true
	default:
		return false, false
	}
}

func fastStartupEnabled() bool {
	var key windows.Handle
	err := windows.RegOpenKeyEx(
		windows.HKEY_LOCAL_MACHINE,
		windows.StringToUTF16Ptr(`SYSTEM\CurrentControlSet\Control\Session Manager\Power`),
		0, windows.KEY_READ, &key,
	)
	if err != nil {
		return false
	}
	defer windows.RegCloseKey(key) //nolint:errcheck

	var val uint32
	var typ uint32
	size := uint32(4)
	name, _ := windows.UTF16PtrFromString("HiberbootEnabled")
	err = windows.RegQueryValueEx(key, name, nil, &typ, (*byte)(unsafe.Pointer(&val)), &size)
	return err == nil && val != 0
}

// ── Preflight safety gates (#63) ─────────────────────────────────────────────

// onBattery reports (running-on-battery, known). Win32_Battery exists only on
// machines that HAVE a battery, so "no instance" means desktop, not danger —
// hence the separate `known` result. Only an affirmative answer may block.
func onBattery() (bool, bool) {
	out, err := runPowerShellOutput(
		`$b = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $b) { Write-Output "nobattery" } elseif ($b.BatteryStatus -eq 1) { Write-Output "onbattery" } else { Write-Output "ac" }`)
	if err != nil {
		return false, false
	}
	switch strings.TrimSpace(out) {
	case "onbattery":
		return true, true
	case "ac":
		return false, true
	default: // "nobattery" — a desktop; nothing to warn about
		return false, false
	}
}

// pendingReboot reports whether Windows is genuinely mid-servicing, and which
// signal said so. A pending servicing operation can rewrite the boot
// configuration underneath us or resume partway through the migration.
//
// DELIBERATELY NARROW. The first version also gated on
// PendingFileRenameOperations, which turns out to be set by ordinary installers
// and to linger on a large share of perfectly healthy machines — it refused a
// freshly-installed Windows in our own E2E (el10-gnome-win11ent, 2026-07-31),
// and would have refused plenty of real users' PCs for no reason. A gate that
// fires on a healthy machine trains people to ignore it, and over-correcting
// manufactures false refusals exactly as it manufactures false test failures.
//
// So: only Component Based Servicing and Windows Update, which mean a servicing
// operation is genuinely staged. Failing to answer is NOT treated as pending —
// our own query breaking must never block a fine machine.
func pendingReboot() (bool, string) {
	out, err := runPowerShellOutput(`$r = @()
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $r += "servicing" }
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $r += "windows-update" }
Write-Output ($r -join ",")`)
	if err != nil {
		return false, ""
	}
	reason := strings.TrimSpace(out)
	return reason != "", reason
}

// hibernated reports whether a hibernation image is sitting on disk. This is
// the one that actually destroys data: a hibernated Windows has in-memory NTFS
// state newer than the disk, and mounting it read-write from Linux corrupts the
// filesystem. Distinct from Fast Startup, which is a registry flag.
func hibernated() bool {
	out, err := runPowerShellOutput(`Write-Output (Test-Path "C:\hiberfil.sys")`)
	if err != nil {
		return false
	}
	return strings.EqualFold(strings.TrimSpace(out), "True")
}

func totalRAMGB() float64 {
	out, err := runPowerShellOutput(
		`Write-Output ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory)`)
	if err != nil {
		return 0
	}
	b, err := strconv.ParseFloat(strings.TrimSpace(out), 64)
	if err != nil {
		return 0
	}
	return b / (1024 * 1024 * 1024)
}

// ── Fast Startup ──────────────────────────────────────────────────────────────

func disableFastStartup() error {
	// `powercfg /h off` is the part that matters and the part we were missing
	// (#63): clearing HiberbootEnabled disables FAST STARTUP, but a genuinely
	// hibernated machine still has hiberfil.sys and a stale on-disk NTFS
	// state. Turning hibernation off removes the file as well, so Linux can
	// mount the volume read-write safely.
	//
	// Best-effort on the powercfg half: on some systems it is policy-disabled,
	// and the registry change is still worth making. The Hibernated gate in
	// getSystemInfo is what actually refuses to proceed.
	if err := runPowerShell(`powercfg.exe /h off`); err != nil {
		// Not fatal — report through the gate, not by aborting here.
		_ = err
	}
	return runPowerShell(`Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" ` +
		`-Name "HiberbootEnabled" -Value 0 -Type DWord -Force`)
}
