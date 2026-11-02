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
	// Do not change power settings until their prior values are durable and
	// the Add/Remove key is positively attributable to this installation.
	if err := recordPriorPowerState(); err != nil {
		return err
	}
	// `powercfg /h off` is the part that matters and the part we were missing
	// (#63): clearing HiberbootEnabled disables FAST STARTUP, but a genuinely
	// hibernated machine still has hiberfil.sys and a stale on-disk NTFS
	// state. Turning hibernation off removes the file as well, so Linux can
	// mount the volume read-write safely.
	if err := runPowerShell(`$ErrorActionPreference='Stop'; powercfg.exe /h off; if ($LASTEXITCODE -ne 0) { throw 'Could not disable hibernation safely' }`); err != nil {
		return err
	}
	return runPowerShell(`$ErrorActionPreference='Stop'; Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" ` +
		`-Name "HiberbootEnabled" -Value 0 -Type DWord -Force; ` +
		`if ((Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name HiberbootEnabled).HiberbootEnabled -ne 0) { throw 'Fast Startup disable was not observed' }`)
}

// priorPowerPath records the pre-install hibernation/Fast Startup state, so
// uninstall restores rather than assumes. Lives under install\ (removed by
// uninstall itself, read first).
func priorPowerPath() string {
	return filepath.Join(wootcDir(), "install", "prior-power.txt")
}

func recordPriorPowerState() error {
	if err := verifyUninstallRegistryOwnership(); err != nil {
		return err
	}
	// A retry never redefines "prior" after an earlier run disabled power.
	var hib, hbb string
	missing := false
	if data, err := os.ReadFile(priorPowerPath()); err == nil {
		hib, hbb = parsePriorPower(string(data))
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("read saved power settings: %w", err)
	} else {
		missing = true
		var err1, err2 error
		hib, err1 = runPowerShellOutput(`$ErrorActionPreference='Stop'; (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name HibernateEnabled).HibernateEnabled`)
		hbb, err2 = runPowerShellOutput(`$ErrorActionPreference='Stop'; (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name HiberbootEnabled).HiberbootEnabled`)
		if err1 != nil || err2 != nil {
			return fmt.Errorf("cannot observe prior hibernation/Fast Startup settings; no settings changed (hibernate: %v; Fast Startup: %v)", err1, err2)
		}
		hib, hbb = strings.TrimSpace(hib), strings.TrimSpace(hbb)
	}
	if (hib != "0" && hib != "1") || (hbb != "0" && hbb != "1") {
		return fmt.Errorf("saved or observed Windows power settings are incomplete; preserve the install record and resolve it before retrying")
	}
	if missing {
		if err := os.MkdirAll(filepath.Dir(priorPowerPath()), 0700); err != nil {
			return err
		}
		file, err := os.OpenFile(priorPowerPath(), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return err
		}
		if _, err := fmt.Fprintf(file, "hibernate=%s\nhiberboot=%s\n", hib, hbb); err != nil {
			_ = file.Close()
			return err
		}
		if err := file.Sync(); err != nil {
			_ = file.Close()
			return err
		}
		if err := file.Close(); err != nil {
			return err
		}
	}
	// The mirror survives removal of the installer folder. A failed mirror
	// write prevents mutation, and a retry reuses the already-durable file.
	return runPowerShell(uninstallRegistryOwnershipScript(true) + fmt.Sprintf(
		`Set-ItemProperty -LiteralPath %s -Name WootcPriorHibernate -Value %s; `+
			`Set-ItemProperty -LiteralPath %s -Name WootcPriorHiberboot -Value %s; `+
			`$saved = Get-ItemProperty -LiteralPath %s; `+
			`if ($saved.WootcPriorHibernate -cne %s -or $saved.WootcPriorHiberboot -cne %s) { throw 'Prior power mirror was not observed' }`,
		powershellLiteral(uninstallRegKey), powershellLiteral(hib), powershellLiteral(uninstallRegKey), powershellLiteral(hbb), powershellLiteral(uninstallRegKey), powershellLiteral(hib), powershellLiteral(hbb)))
}

// readPriorPowerMirror distinguishes absence from a failed observation.
func readPriorPowerMirror() (hibernate, hiberboot string, err error) {
	out, err := runPowerShellOutput(uninstallRegistryOwnershipScript(false) + fmt.Sprintf(
		`if (Test-Path -LiteralPath %s) { $saved = Get-ItemProperty -LiteralPath %s; `+
			`[pscustomobject]@{hibernate=[string]$saved.WootcPriorHibernate;hiberboot=[string]$saved.WootcPriorHiberboot} | ConvertTo-Json -Compress }`,
		powershellLiteral(uninstallRegKey), powershellLiteral(uninstallRegKey)))
	if err != nil {
		return "", "", fmt.Errorf("observe saved power mirror: %w", err)
	}
	if strings.TrimSpace(out) == "" {
		return "", "", nil
	}
	var saved struct {
		Hibernate string `json:"hibernate"`
		Hiberboot string `json:"hiberboot"`
	}
	if err := unmarshalJSON([]byte(out), &saved); err != nil {
		return "", "", fmt.Errorf("parse saved power mirror: %w", err)
	}
	return saved.Hibernate, saved.Hiberboot, nil
}

// restorePriorPowerState restores recorded enabled settings and observes the
// result. The caller must retain the marker and registry mirror on failure.
func restorePriorPowerState() error {
	hibernate, hiberboot, err := priorPowerValues()
	if err != nil {
		return err
	}
	if hibernate == "" && hiberboot == "" {
		return nil // No recorded change, as on a fresh uninstall.
	}
	if (hibernate != "0" && hibernate != "1") || (hiberboot != "0" && hiberboot != "1") {
		return fmt.Errorf("saved Windows power settings are incomplete; keeping both restore records")
	}
	if hibernate == "1" {
		if err := runPowerShell(`$ErrorActionPreference='Stop'; powercfg.exe /h on; ` +
			`if ($LASTEXITCODE -ne 0) { throw 'Could not restore hibernation' }; ` +
			`if ((Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name HibernateEnabled).HibernateEnabled -ne 1) { throw 'Hibernation restoration was not observed' }`); err != nil {
			return fmt.Errorf("restore hibernation: %w", err)
		}
	}
	if hiberboot == "1" {
		if err := runPowerShell(`$ErrorActionPreference='Stop'; Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" ` +
			`-Name "HiberbootEnabled" -Value 1 -Type DWord -Force; ` +
			`if ((Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name HiberbootEnabled).HiberbootEnabled -ne 1) { throw 'Fast Startup restoration was not observed' }`); err != nil {
			return fmt.Errorf("restore Fast Startup: %w", err)
		}
	}
	return nil
}

// priorPowerValues resolves the recorded pre-install state, file first and
// registry mirror second. The file is authoritative when present; the mirror
// is what makes the orphaned-leftovers path restorable at all, because that
// path begins by deleting the file.
func priorPowerValues() (hibernate, hiberboot string, err error) {
	if b, err := os.ReadFile(priorPowerPath()); err == nil {
		hibernate, hiberboot = parsePriorPower(string(b))
		return hibernate, hiberboot, nil
	} else if !os.IsNotExist(err) {
		return "", "", fmt.Errorf("read saved power settings: %w", err)
	}
	return readPriorPowerMirror()
}
