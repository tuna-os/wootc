//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"regexp"
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
	// they already have. Under over-the-shoulder UAC, user.Current() is the
	// elevating admin — derive the machine's interactive human instead (#197, #225).
	envUser := getElevationEnvUser()
	interactiveUser := queryInteractiveUser()
	var currentUser string
	if u, err := user.Current(); err == nil {
		currentUser = u.Username
	}
	info.SuggestedUsername = deriveHumanUsername(envUser, interactiveUser, currentUser)

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

	// Which Microsoft UEFI CA generation does this firmware trust? (#322)
	// Only worth asking when Secure Boot is actually on — with it off the
	// firmware launches an unsigned loader too, and the db read costs a
	// PowerShell spawn on a screen the user is waiting for.
	if info.SecureBootOn {
		info.TrustedUefiAuthorities = trustedUefiAuthorities()
		if v := checkSecureBootChain(info.SecureBootOn, info.SecureBootKnown,
			info.TrustedUefiAuthorities, stagedShimAuthorities()); v.Warn {
			info.SecureBootChainWarning = v.Message
		}
	}

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

// getUninstallInfo locates root.disk across C: and any data volumes, detects
// partial/staged/armed/failed/orphaned states, and reports whether storage sits
// on a wootc-created dedicated partition (SPEC §5).
func getUninstallInfo() UninstallInfo {
	// 1. Search C: first, then any fixed volume, for wootc\disks\root.{vhdx,disk}.
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
				Found:        true,
				StorageDrive: d,
				DiskPath:     p,
				DiskSizeGB:   float64(st.Size()) / (1 << 30),
				Deployed:     deployHasCompleted(d),
			}
			if d != "C" {
				info.OnDedicatedVol, info.ReclaimGB = dedicatedVolumeInfo(d)
				if info.OnDedicatedVol {
					info.VolumeLabel = DedicatedVolumeLabel
				}
			}
			return info
		}
	}

	// 2. No root.disk found on any volume, but check for partial-install or
	// leftover wootc directory across drives (staged, armed, failed, or partial).
	for _, d := range drives {
		wootcPath := d + `:\wootc`
		if st, err := os.Stat(wootcPath); err == nil && st.IsDir() {
			info := UninstallInfo{
				Found:        true,
				StorageDrive: d,
				Orphaned:     true,
				Deployed:     deployHasCompleted(d),
			}
			if d != "C" {
				info.OnDedicatedVol, info.ReclaimGB = dedicatedVolumeInfo(d)
			}
			return info
		}
	}

	// 3. Check for a dedicated wootc-data volume even if \wootc was hand-deleted.
	for _, dp := range listDataPartitions() {
		if isDed, reclaim := dedicatedVolumeInfo(dp.Letter); isDed {
			return UninstallInfo{
				Found:          true,
				StorageDrive:   dp.Letter,
				Orphaned:       true,
				OnDedicatedVol: true,
				ReclaimGB:      reclaim,
			}
		}
	}

	// 4. Check for system-wide wootc artifacts (BCD entries, ESP files, or registry).
	if hasWootcBCDEntry() || hasWootcESPArtifacts() || hasUninstallRegistryEntry() {
		return UninstallInfo{Found: true, StorageDrive: "C", Orphaned: true}
	}

	return UninstallInfo{Found: false}
}

// hasWootcBCDEntry reports whether BCD contains any wootc firmware entry or
// active one-shot bootsequence pointing to wootc.
func hasWootcBCDEntry() bool {
	out, err := runCmd("bcdedit", "/enum", "firmware")
	if err == nil {
		re := regexp.MustCompile(`(?ms)identifier\s+(\{[^}]+\})[^{]*?description\s+wootc\s*$`)
		if re.MatchString(out) {
			return true
		}
	}
	mgrOut, err := runCmd("bcdedit", "/enum", "{fwbootmgr}")
	if err == nil && strings.Contains(strings.ToLower(mgrOut), "wootc") {
		return true
	}
	return false
}

// hasWootcESPArtifacts reports whether the ESP contains any wootc-owned files
// or directories.
func hasWootcESPArtifacts() bool {
	espPath, err := findESP()
	if err != nil {
		return false
	}
	if _, err := os.Stat(filepath.Join(espPath, "EFI", "wootc")); err == nil {
		return true
	}
	if ownsFedoraNamespace(espPath) {
		return true
	}
	redhatGrub := filepath.Join(espPath, "EFI", "redhat", "grub.cfg")
	if data, err := os.ReadFile(redhatGrub); err == nil && strings.Contains(string(data), wootcGrubOwnership) {
		return true
	}
	loaderConf := filepath.Join(espPath, "loader", "loader.conf")
	if data, err := os.ReadFile(loaderConf); err == nil && strings.Contains(string(data), wootcGrubOwnership) {
		return true
	}
	return false
}

// hasUninstallRegistryEntry reports whether the Add/Remove Programs key exists.
func hasUninstallRegistryEntry() bool {
	out, err := runPowerShellOutput(fmt.Sprintf(
		`if (Test-Path %q) { Write-Output 'EXISTS' }`, uninstallRegKey))
	return err == nil && strings.TrimSpace(out) == "EXISTS"
}

// cleanupESP removes all wootc-staged files and directories from the ESP.
func cleanupESP() error {
	espPath, err := findESP()
	if err != nil {
		return nil
	}

	// 1. Remove EFI\wootc (our own namespace)
	_ = os.RemoveAll(filepath.Join(espPath, "EFI", "wootc"))

	// 2. Remove EFI\fedora if staged by wootc (verified via "# wootc" ownership marker)
	if ownsFedoraNamespace(espPath) {
		_ = os.RemoveAll(filepath.Join(espPath, "EFI", "fedora"))
	}

	// 3. Remove EFI\redhat if staged by wootc
	redhatGrub := filepath.Join(espPath, "EFI", "redhat", "grub.cfg")
	if data, err := os.ReadFile(redhatGrub); err == nil && strings.Contains(string(data), wootcGrubOwnership) {
		_ = os.RemoveAll(filepath.Join(espPath, "EFI", "redhat"))
	}

	// 4. Remove systemd-boot loader configuration if staged by wootc
	loaderConf := filepath.Join(espPath, "loader", "loader.conf")
	if data, err := os.ReadFile(loaderConf); err == nil && strings.Contains(string(data), wootcGrubOwnership) {
		_ = os.Remove(filepath.Join(espPath, "loader", "entries", "wootc-deployer.conf"))
		_ = os.Remove(loaderConf)
		_ = os.RemoveAll(filepath.Join(espPath, "EFI", "systemd"))
	}

	return nil
}

// deployHasCompleted reports whether the deployer has finished at least once
// on this machine based on lifecycle state in state.json (written by deploy.sh
// on completion as "deployed", or by first boot as "healthy").
func deployHasCompleted(drive string) bool {
	if s, ok := readState(); ok && (s.State == StateDeployed || s.State == StateHealthy) {
		return true
	}
	if drive != "" {
		p := filepath.Join(drive+`:\wootc`, "state.json")
		if s, ok := readStateFrom(p); ok && (s.State == StateDeployed || s.State == StateHealthy) {
			return true
		}
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

	// Determine where wootc lives (default C: when nothing found).
	drive := "C"
	if info.Found && info.StorageDrive != "" {
		drive = info.StorageDrive
	}
	setStorageDrive(drive)

	var errs []string

	// 0. Put back what install changed outside its folder: hibernation /
	// Fast Startup (read the marker / registry BEFORE the install dir and
	// Add/Remove key are removed). "Windows is unchanged" must be true.
	restorePriorPowerState()
	unregisterUninstallEntry()

	// 1. Remove all wootc BCD entries and disarm one-shot bootsequence.
	deleteWootcBCDEntries()
	disarmOneShot()

	// 2. Remove ESP files (ownership-aware).
	if err := cleanupESP(); err != nil {
		errs = append(errs, fmt.Sprintf("cleaning ESP files: %v", err))
	}

	// 3. Remove the install dir, staged files, cache, and logs.
	// Clean both the active storage drive and C: if distinct.
	targetDrives := []string{drive}
	if drive != "C" {
		targetDrives = append(targetDrives, "C")
	}
	for _, d := range targetDrives {
		wDir := d + `:\wootc`
		if _, err := os.Stat(wDir); err != nil {
			continue
		}
		// Always remove install, bundle, cache, logs, state.json, and metadata
		for _, sub := range []string{"install", "bundle", "cache", "logs"} {
			_ = os.RemoveAll(filepath.Join(wDir, sub))
		}
		for _, loose := range []string{"state.json", "channel.txt", "brand.css", "brand.json", "e2e-drive.json", "e2e-drive-state.json"} {
			_ = os.Remove(filepath.Join(wDir, loose))
		}

		rootDiskExists := false
		for _, name := range []string{"root.disk", "root.vhdx"} {
			if _, err := os.Stat(filepath.Join(wDir, "disks", name)); err == nil {
				rootDiskExists = true
				break
			}
		}

		// root.disk only on request. If no root.disk exists (partial/orphaned),
		// clean up the entire folder.
		if opts.DeleteRootDisk || opts.RemovePartition || !rootDiskExists {
			_ = os.RemoveAll(filepath.Join(wDir, "disks"))
			_ = os.RemoveAll(wDir)
		}
	}

	// 4. Optionally remove a wootc-created data partition and extend C:.
	if opts.RemovePartition && info.Found && info.OnDedicatedVol && drive != "C" {
		if err := removePartitionAndExtendC(drive); err != nil {
			errs = append(errs, fmt.Sprintf("removing data partition %s: %v", drive, err))
		}
	}

	// 5. Verification pass: ensure all wootc-owned boot artifacts and installer
	// state are gone and report failures if anything remained.
	if vErrs := verifyUninstallClean(opts, drive); len(vErrs) > 0 {
		errs = append(errs, vErrs...)
	}

	if len(errs) > 0 {
		return fmt.Errorf("uninstall cleanup incomplete:\n- %s", strings.Join(errs, "\n- "))
	}
	return nil
}

// verifyUninstallClean inspects the system to ensure that all wootc-owned
// boot entries, ESP files, registry keys, and directories were removed.
func verifyUninstallClean(opts UninstallOptions, storageDrive string) []string {
	var errs []string

	if hasWootcBCDEntry() {
		errs = append(errs, "a wootc BCD firmware entry is still present")
	}

	if hasWootcESPArtifacts() {
		errs = append(errs, "wootc boot files are still present on the ESP")
	}

	if hasUninstallRegistryEntry() {
		errs = append(errs, "Add/Remove Programs registry entry is still present")
	}

	for _, d := range []string{storageDrive, "C"} {
		installPath := d + `:\wootc\install`
		if _, err := os.Stat(installPath); err == nil {
			errs = append(errs, fmt.Sprintf("%s was not removed", installPath))
		}
	}

	if opts.DeleteRootDisk || opts.RemovePartition {
		for _, d := range []string{storageDrive, "C"} {
			wDir := d + `:\wootc`
			if _, err := os.Stat(wDir); err == nil {
				errs = append(errs, fmt.Sprintf("%s was not fully removed", wDir))
			}
		}
	}

	if opts.RemovePartition && storageDrive != "C" {
		if isDed, _ := dedicatedVolumeInfo(storageDrive); isDed {
			errs = append(errs, fmt.Sprintf("dedicated volume %s: was not removed", storageDrive))
		}
	}

	return errs
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

// ── Interactive user derivation (over-the-shoulder UAC) ───────────────────────

func getElevationEnvUser() string {
	for _, env := range []string{"WOOTC_ORIGINAL_USER", "WOOTC_INTERACTIVE_USER"} {
		if val := strings.TrimSpace(os.Getenv(env)); val != "" {
			return val
		}
	}
	return ""
}

func queryInteractiveUser() string {
	// Under over-the-shoulder UAC, user.Current() gives the elevating admin.
	// Win32_ComputerSystem.UserName or explorer.exe process owner identifies
	// the interactive desktop user (#197, #225).
	psScript := `$u = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
if (-not $u) { $u = (Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName }
if (-not $u) {
    $exp = Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exp) {
        $owner = Invoke-CimMethod -InputObject $exp -MethodName GetOwner -ErrorAction SilentlyContinue
        if ($owner -and $owner.User) {
            if ($owner.Domain) { $u = "$($owner.Domain)\$($owner.User)" } else { $u = $owner.User }
        }
    }
}
if (-not $u) {
    $exp = Get-WmiObject Win32_Process -Filter "name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exp) {
        $o = $exp.GetOwner()
        if ($o -and $o.User) {
            if ($o.Domain) { $u = "$($o.Domain)\$($o.User)" } else { $u = $o.User }
        }
    }
}
if ($u) { Write-Output $u }`

	out, err := runPowerShellOutput(psScript)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

