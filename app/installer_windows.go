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
	if h, err := os.Hostname(); err == nil {
		info.SuggestedHostname = sanitizeHostname(h)
	}
	// Same idea for the account name, so the launchpad can collect only a
	// password by default instead of asking the user to invent an identity
	// they already have. os/user gives DOMAIN\User on Windows; the sanitiser
	// takes the account part.
	if u, err := user.Current(); err == nil {
		info.SuggestedUsername = sanitizeUsername(u.Username)
	}

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
			}
			if d != "C" {
				info.OnDedicatedVol, info.ReclaimGB = dedicatedVolumeInfo(d)
			}
			return info
		}
	}
	return UninstallInfo{Found: false}
}

func uninstallWith(ctx context.Context, opts UninstallOptions) error {
	info := getUninstallInfo()

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

// ── Reboot ────────────────────────────────────────────────────────────────────

func rebootWindows() error {
	_, err := runCmd("shutdown", "/r", "/t", "5", "/f",
		"/c", "wootc is rebooting to start the installer")
	return err
}
