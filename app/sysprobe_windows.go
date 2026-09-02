//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
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
	// Record what is about to change so uninstall can put it back. Without
	// this, "Windows is unchanged" after uninstall was false: hibernation
	// stayed permanently off (the audit's finding). Best-effort — a missing
	// marker just means uninstall leaves power settings alone.
	recordPriorPowerState()
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

// priorPowerPath records the pre-install hibernation/Fast Startup state, so
// uninstall restores rather than assumes. Lives under install\ (removed by
// uninstall itself, read first).
func priorPowerPath() string {
	return filepath.Join(wootcDir(), "install", "prior-power.txt")
}

func recordPriorPowerState() {
	// Only the FIRST install on this machine gets to define "prior": a
	// reinstall after wootc already turned things off must not record the
	// off state as the thing to restore to.
	if _, err := os.Stat(priorPowerPath()); err == nil {
		return
	}
	hibernate, err1 := runPowerShellOutput(`(Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled`)
	hiberboot, err2 := runPowerShellOutput(`(Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled`)
	if err1 != nil && err2 != nil {
		return
	}
	hib, hbb := strings.TrimSpace(hibernate), strings.TrimSpace(hiberboot)
	content := fmt.Sprintf("hibernate=%s\nhiberboot=%s\n", hib, hbb)
	_ = os.MkdirAll(filepath.Dir(priorPowerPath()), 0o755)
	_ = os.WriteFile(priorPowerPath(), []byte(content), 0o644)
	// Mirror into the Add/Remove key, which survives what the file cannot.
	// The file lives under C:\wootc\install — so a user who deletes C:\wootc
	// by hand and THEN uninstalls (the orphaned-leftovers path, and a case
	// #238 tests explicitly) destroys the only record of what to restore, and
	// restorePriorPowerState() silently returns having changed nothing:
	// hibernation stays off forever on a machine we promised to leave
	// unchanged. The registry key is removed by unregisterUninstallEntry(),
	// which runs immediately AFTER the restore, so the mirror outlives exactly
	// the window it is needed for.
	_ = runPowerShell(fmt.Sprintf(
		`New-Item -Path %q -Force | Out-Null; `+
			`Set-ItemProperty -Path %q -Name WootcPriorHibernate -Value %q; `+
			`Set-ItemProperty -Path %q -Name WootcPriorHiberboot -Value %q`,
		uninstallRegKey, uninstallRegKey, hib, uninstallRegKey, hbb))
}

// readPriorPowerMirror reads the registry copy of the pre-install power state.
// Returns ("", "") when no mirror exists — an install that predates the mirror,
// or a machine wootc never touched.
func readPriorPowerMirror() (hibernate, hiberboot string) {
	h, err1 := runPowerShellOutput(fmt.Sprintf(
		`(Get-ItemProperty -Path %q -Name WootcPriorHibernate -ErrorAction SilentlyContinue).WootcPriorHibernate`,
		uninstallRegKey))
	b, err2 := runPowerShellOutput(fmt.Sprintf(
		`(Get-ItemProperty -Path %q -Name WootcPriorHiberboot -ErrorAction SilentlyContinue).WootcPriorHiberboot`,
		uninstallRegKey))
	if err1 != nil {
		h = ""
	}
	if err2 != nil {
		b = ""
	}
	return strings.TrimSpace(h), strings.TrimSpace(b)
}

// restorePriorPowerState re-enables hibernation / Fast Startup if — and only
// if — they were on before wootc touched them. Best-effort by design.
func restorePriorPowerState() {
	hibernate, hiberboot := priorPowerValues()
	if hibernate == "1" {
		_ = runPowerShell(`powercfg.exe /h on`)
	}
	if hiberboot == "1" {
		_ = runPowerShell(`Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" ` +
			`-Name "HiberbootEnabled" -Value 1 -Type DWord -Force`)
	}
}

// priorPowerValues resolves the recorded pre-install state, file first and
// registry mirror second. The file is authoritative when present; the mirror
// is what makes the orphaned-leftovers path restorable at all, because that
// path begins by deleting the file.
func priorPowerValues() (hibernate, hiberboot string) {
	if b, err := os.ReadFile(priorPowerPath()); err == nil {
		return parsePriorPower(string(b))
	}
	return readPriorPowerMirror()
}
