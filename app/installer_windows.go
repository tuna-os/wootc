//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"golang.org/x/sys/windows"
)

// ── System info ───────────────────────────────────────────────────────────────

func getSystemInfo() SystemInfo {
	info := SystemInfo{IsUEFI: isUEFI()}

	// Carry the machine's existing identity across the migration (#174): the
	// user already knows this name. Sanitised because Windows computer names
	// permit characters (underscores especially) that Linux hostnames do not.
	// Both suggestions fall back rather than coming back empty — a derived
	// identity is what keeps these fields under Advanced, so the default
	// form asks for a password and nothing else.
	rawHost, _ := os.Hostname()
	info.SuggestedHostname = suggestHostname(rawHost)
	// Same idea for the account name, so the launchpad can collect only a
	// password by default instead of asking the user to invent an identity
	// they already have. os/user gives DOMAIN\User on Windows; the sanitiser
	// takes the account part.
	var rawUser string
	if u, err := user.Current(); err == nil {
		rawUser = u.Username
	}
	info.SuggestedUsername = suggestUsername(rawUser)

	// OS version
	v := windows.RtlGetVersion()
	if v != nil {
		info.OSVersion = fmt.Sprintf("Windows %d.%d.%d", v.MajorVersion, v.MinorVersion, v.BuildNumber)
	}

	// Free disk on C:
	var freeBytesAvail, totalBytes uint64
	p, _ := syscall.UTF16PtrFromString(`C:\`)
	windows.GetDiskFreeSpaceEx(p, &freeBytesAvail, &totalBytes, nil) //nolint:errcheck
	info.FreeDiskGB = float64(freeBytesAvail) / (1 << 30)
	info.TotalDiskGB = float64(totalBytes) / (1 << 30)

	// BitLocker: detailed C: state (SPEC §3.5).
	info.BitLockerState = bitlockerState(`C:`)
	info.BitLockerOn = info.BitLockerState == "on" || info.BitLockerState == "encrypting"

	// Candidate data partitions for the BitLocker (auto/manual) path.
	info.DataPartitions = listDataPartitions()

	// Fast Startup: HKLM\...\Power HiberbootEnabled != 0
	info.FastStartupOn = fastStartupEnabled()

	// Secure Boot
	info.SecureBootOn, info.SecureBootKnown = secureBootState()

	// Advisory NTFS fragmentation analysis (SPEC §3.6). Failure to analyze
	// must not block installation.
	info.DefragRecommended = defragRecommended(`C:`)

	// Preflight safety gates (#63). Every one of these is "is it safe to
	// START", not "did something break" — they are checked before the first
	// byte is written, because after the shrink there is no cheap undo.
	info.OnBattery, info.BatteryKnown = onBattery()
	info.PendingReboot, info.PendingRebootReason = pendingReboot()
	info.Hibernated = hibernated()
	info.RAMGB = totalRAMGB()
	info.Is64Bit = runtime.GOARCH == "amd64" || runtime.GOARCH == "arm64"

	// BitLocker recovery-key warning: honest disclosure (#63). When C: is
	// BitLocker-protected, the user should record their recovery key before
	// any migration step, regardless of whether we unlock C: or carve a
	// separate volume (#61).
	info.BitLockerRecoveryKeyWarning = info.BitLockerState == "on"

	return info
}

// ── Pre-flight checks ─────────────────────────────────────────────────────────

func validatePlatformConfig(cfg InstallConfig) error {
	if cfg.Bootloader != "systemd-boot" {
		return nil
	}
	asset, err := systemdBootAsset()
	if err != nil {
		return err
	}
	on, known := secureBootState()
	if (on || !known) && !asset.trustedChain {
		state := "enabled"
		if !known {
			state = "unknown"
		}
		return fmt.Errorf("Secure Boot is %s and systemd-boot is not verifiably trusted; choose GRUB2 or explicitly turn Secure Boot off", state)
	}
	return nil
}

func checkSystem() error {
	if !isAdmin() {
		return fmt.Errorf("wootc must be run as Administrator")
	}
	if !isUEFI() {
		return fmt.Errorf("this PC starts Windows in legacy BIOS mode — wootc needs UEFI. " +
			"Most PCs made after 2012 support UEFI; it can usually be enabled in firmware setup")
	}
	// SPEC §3.5: never touch a volume mid-(de)cryption — the partition
	// table is unstable and a resize could corrupt it.
	switch bitlockerState(`C:`) {
	case "encrypting":
		return fmt.Errorf("Windows is still encrypting drive C:. Wait for BitLocker to finish " +
			"(you can check progress in the BitLocker control panel), then run wootc again")
	case "decrypting":
		return fmt.Errorf("Windows is still decrypting drive C:. Wait for it to finish, then run wootc again")
	}
	return nil
}

// ── Directories ───────────────────────────────────────────────────────────────

func createDirectories() error {
	dirs := []string{
		filepath.Join(wootcDir(), "install"),
		filepath.Join(wootcDir(), "disks"),
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return fmt.Errorf("mkdir %s: %w", d, err)
		}
	}
	return nil
}

func uninstall(ctx context.Context) error {
	// Default: remove boot entry + ESP + install dir, keep root.disk.
	return uninstallWith(ctx, UninstallOptions{})
}

// getUninstallInfo locates root.disk across C: and any data volumes and
// reports whether it sits on a wootc-created dedicated partition (SPEC §5).
func getUninstallInfo() UninstallInfo {
	// Search C: first, then any fixed volume, for wootc\disks\root.{vhdx,disk}.
	drives := []string{"C"}
	for _, dp := range listDataPartitions() {
		drives = append(drives, dp.Letter)
	}
	for _, d := range drives {
		for _, name := range []string{"root.vhdx", "root.disk"} {
			p := d + `:\wootc\disks\` + name
			st, err := os.Stat(p)
			if err != nil {
				continue
			}
			info := UninstallInfo{
				Found: true, StorageDrive: d, DiskPath: p,
				DiskSizeGB: float64(st.Size()) / (1 << 30),
				Deployed:   deployHasCompleted(d),
			}
			if d != "C" {
				info.OnDedicatedVol, info.ReclaimGB = dedicatedVolumeInfo(d)
			}
			return info
		}
	}
	// No disk anywhere — but leftover arming means there is still something
	// to clean up, and previously NO GUI path could reach it: a hand-deleted
	// C:\wootc dropped the user on the launchpad with a stale boot entry
	// forever. Surface it so the control panel can offer the uninstall.
	for _, marker := range []string{
		`C:\wootc\install\bcd-guid.txt`,
		`C:\wootc\state.json`,
	} {
		if _, err := os.Stat(marker); err == nil {
			return UninstallInfo{Found: true, StorageDrive: "C", Orphaned: true}
		}
	}
	return UninstallInfo{Found: false}
}

// deployHasCompleted reports whether the deployer has finished at least once
// on this machine: its staged journal is the physical evidence, the
// lifecycle state the declared one. Either suffices — this only unlocks a
// "restart into TunaOS" offer, and arming a one-shot at a non-deployed ESP
// still just boots the deployer.
func deployHasCompleted(drive string) bool {
	if _, err := os.Stat(drive + `:\wootc\logs\deployer-last-journal.log`); err == nil {
		return true
	}
	if s, ok := readState(); ok && (s.State == StateDeployed || s.State == StateHealthy) {
		return true
	}
	return false
}

// armOneShotFromPersistedGUID re-arms the existing wootc firmware entry for
// exactly one boot (bootsequence, never displayorder — Windows stays the
// default). The entry survives the deploy; the ESP behind it now boots
// Phase-2 TunaOS.
func armOneShotFromPersistedGUID() error {
	b, err := os.ReadFile(filepath.Join(wootcDir(), "install", "bcd-guid.txt"))
	if err != nil {
		return fmt.Errorf("no boot entry is recorded for this install (bcd-guid.txt): %w — reinstalling repairs this", err)
	}
	guid := strings.TrimSpace(string(b))
	if !strings.HasPrefix(guid, "{") {
		return fmt.Errorf("recorded boot entry id looks invalid (%q) — reinstalling repairs this", guid)
	}
	if out, err := runCmd("bcdedit", "/set", "{fwbootmgr}", "bootsequence", guid, "/addfirst"); err != nil {
		return fmt.Errorf("could not arm the one-time TunaOS boot: %w (output: %s)", err, out)
	}
	return nil
}

// ctx is accepted for signature symmetry with the install path but is
// deliberately NOT honoured as a cancellation point (#191). Uninstall is an
// ordered sequence of destructive cleanups — BCD entries, ESP files, then the
// wootc directory — and abandoning it midway leaves a machine that is neither
// migrated nor restored: a boot entry pointing at files that are gone is worse
// than either end state. If cancellation is ever wanted here it needs an
// explicit rollback story, not a ctx check dropped between steps.
func uninstallWith(ctx context.Context, opts UninstallOptions) error {
	_ = ctx
	info := getUninstallInfo()

	// 0. Put back what install changed outside its folder: hibernation /
	// Fast Startup (read the marker BEFORE the install dir is removed), and
	// the Add/Remove Programs entry. "Windows is unchanged" must be true.
	restorePriorPowerState()
	unregisterUninstallEntry()
	_ = unregisterRecoveryTasks()

	// 1. Remove all wootc BCD entries.
	deleteWootcBCDEntries()

	// 2. Remove ESP files. EFI\fedora only when its grub.cfg is ours — the
	// shared "# wootc" family, so a post-deploy Phase-2 menu is cleaned up
	// too instead of stranding wootc's chain on the ESP forever.
	if espPath, err := findESP(); err == nil {
		os.RemoveAll(filepath.Join(espPath, "EFI", "wootc")) //nolint:errcheck
		grubCfg := filepath.Join(espPath, "EFI", "fedora", "grub.cfg")
		if data, err := os.ReadFile(grubCfg); err == nil && strings.Contains(string(data), wootcGrubOwnership) {
			os.RemoveAll(filepath.Join(espPath, "EFI", "fedora")) //nolint:errcheck
		}
	}

	// Determine where wootc lives (default C: when nothing found).
	drive := "C"
	if info.Found {
		drive = info.StorageDrive
	}
	setStorageDrive(drive)

	// 3. Remove the install dir (kernel/vault). root.disk only on request.
	os.RemoveAll(filepath.Join(wootcDir(), "install")) //nolint:errcheck
	if opts.DeleteRootDisk || opts.RemovePartition {
		os.RemoveAll(filepath.Join(wootcDir(), "disks")) //nolint:errcheck
		os.RemoveAll(wootcDir())                         //nolint:errcheck
	}

	// 4. Optionally remove a wootc-created data partition and extend C:.
	if opts.RemovePartition && info.Found && info.OnDedicatedVol && drive != "C" {
		if err := removePartitionAndExtendC(drive); err != nil {
			return fmt.Errorf("removing data partition %s: %w", drive, err)
		}
	}
	return nil
}

// ── Add/Remove Programs ───────────────────────────────────────────────────────
// The audit's discoverability finding: wootc registered itself nowhere
// Windows looks, so "how do I remove this?" had no answer a normal user
// could find. One Uninstall registry entry fixes that; the string points at
// the documented headless `wootc.exe uninstall` (keep-root.disk default).

const uninstallRegKey = `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\wootc`

func registerUninstallEntry() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	// The generic build keeps its documented "TunaOS (wootc)" listing;
	// branded builds list under the distribution's own name — a Bazzite user
	// searching Apps for "wootc" would find nothing, because nothing ever
	// told them that word.
	b := effectiveBranding()
	displayName := b.Name
	if strings.EqualFold(b.ProductName, "wootc") {
		displayName = b.Name + " (wootc)"
	}
	_ = runPowerShell(fmt.Sprintf(
		`New-Item -Path %q -Force | Out-Null; `+
			`Set-ItemProperty -Path %q -Name DisplayName -Value %q; `+
			`Set-ItemProperty -Path %q -Name Publisher -Value "tuna-os"; `+
			`Set-ItemProperty -Path %q -Name DisplayIcon -Value %q; `+
			`Set-ItemProperty -Path %q -Name InstallLocation -Value "C:\wootc"; `+
			`Set-ItemProperty -Path %q -Name UninstallString -Value %q; `+
			`Set-ItemProperty -Path %q -Name NoModify -Value 1 -Type DWord; `+
			`Set-ItemProperty -Path %q -Name NoRepair -Value 1 -Type DWord`,
		uninstallRegKey, uninstallRegKey, displayName, uninstallRegKey, uninstallRegKey, exe,
		uninstallRegKey, uninstallRegKey, fmt.Sprintf(`"%s" uninstall`, exe),
		uninstallRegKey, uninstallRegKey))
}

func unregisterUninstallEntry() {
	_ = runPowerShell(fmt.Sprintf(
		`Remove-Item -Path %q -Recurse -Force -ErrorAction SilentlyContinue`, uninstallRegKey))
}

// ── Reboot ────────────────────────────────────────────────────────────────────

func rebootWindows() error {
	_, err := runCmd("shutdown", "/r", "/t", "5", "/f",
		"/c", effectiveBranding().ProductName+" is rebooting to start the installer")
	return err
}
