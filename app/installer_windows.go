//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"golang.org/x/sys/windows"
)

// ── System info ───────────────────────────────────────────────────────────────

// readPlanSystemInfo reads only the facts an install plan check uses: the
// channel gate (BitLocker, the Secure Boot chain) and the grant's
// disclosures (BitLocker, Fast Startup, the Secure Boot chain warning). The
// native plan check runs inside the shell's deadline, so it must not wait on
// the advisory probes getSystemInfo adds for the launchpad, above all the
// whole-volume fragmentation analysis (defrag.exe /A), whose time grows with
// the volume and has no bound.
func readPlanSystemInfo() SystemInfo {
	var info SystemInfo
	// BitLocker: detailed C: state (SPEC §3.5).
	info.BitLockerState = bitlockerState(`C:`)
	info.BitLockerOn = info.BitLockerState == "on" || info.BitLockerState == "encrypting"

	// Fast Startup: HKLM\...\Power HiberbootEnabled != 0
	info.FastStartupOn = fastStartupEnabled()

	// Secure Boot
	info.SecureBootOn, info.SecureBootKnown = secureBootState()

	// Which Microsoft UEFI CA generation does this firmware trust? (#322)
	// Only worth asking when Secure Boot is actually on — with it off the
	// firmware launches an unsigned loader too, and the db read costs a
	// PowerShell spawn on a screen the user is waiting for.
	if info.SecureBootOn {
		info.TrustedUefiAuthorities, info.UefiDbRead = trustedUefiAuthorities()
		if v := secureBootChainVerdict(info); v.Warn {
			info.SecureBootChainWarning = v.Message
		}
	}

	// BitLocker recovery-key warning: honest disclosure (#63). When C: is
	// BitLocker-protected, the user should record their recovery key before
	// any migration step, regardless of whether we unlock C: or carve a
	// separate volume (#61).
	info.BitLockerRecoveryKeyWarning = info.BitLockerState == "on"
	return info
}

func getSystemInfo() SystemInfo {
	info := readPlanSystemInfo()
	info.IsUEFI = isUEFI()

	// Carry the machine's existing identity across the migration (#174): the
	// user already knows this name. Sanitised because Windows computer names
	// permit characters (underscores especially) that Linux hostnames do not.
	// Both suggestions fall back rather than coming back empty — a derived
	// identity is what keeps these fields under Advanced, so the default
	// form asks for a password and nothing else.
	rawHost, _ := os.Hostname()
	info.SuggestedHostname = suggestHostname(rawHost)
	// A suggestion is safe only when the elevated account is the signed-in
	// person. checkSystem enforces the same SID gate before any mutation.
	info.SuggestedUsername, _ = verifiedPrimaryUsername()

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

	// Candidate data partitions for the BitLocker (auto/manual) path.
	info.DataPartitions = listDataPartitions()

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
		return fmt.Errorf("%s must be run as Administrator", productName())
	}
	if _, err := verifiedPrimaryUsername(); err != nil {
		return err
	}
	if !isUEFI() {
		return fmt.Errorf("this PC starts Windows in legacy BIOS mode — %s needs UEFI. "+
			"Most PCs made after 2012 support UEFI; it can usually be enabled in firmware setup", productName())
	}
	// SPEC §3.5: never touch a volume mid-(de)cryption — the partition
	// table is unstable and a resize could corrupt it.
	switch bitlockerState(`C:`) {
	case "encrypting":
		return fmt.Errorf("Windows is still encrypting drive C:. Wait for BitLocker to finish "+
			"(you can check progress in the BitLocker control panel), then run %s again", productName())
	case "decrypting":
		return fmt.Errorf("Windows is still decrypting drive C:. Wait for it to finish, then run %s again", productName())
	}
	return nil
}

// storageFreeBytes reads the free space the calling user can use on drive
// letter (the volume root.disk and the deployer scratch land on).
func storageFreeBytes(drive string) (uint64, bool) {
	p, err := windows.UTF16PtrFromString(drive + `:\`)
	if err != nil {
		return 0, false
	}
	var available, total uint64
	if err := windows.GetDiskFreeSpaceEx(p, &available, &total, nil); err != nil {
		return 0, false
	}
	return available, true
}

// storageWootcDir is <drive>:\wootc; "" is the current storage drive.
func storageWootcDir(drive string) string {
	if drive == "" {
		return wootcDir()
	}
	return drive + `:\wootc`
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
	trustedDrives := drives[:0]
	for _, d := range drives {
		root := d + `:\wootc`
		if _, err := os.Lstat(root); err != nil {
			continue
		}
		if err := ensureTrustedStateDirectory(root); err == nil {
			trustedDrives = append(trustedDrives, d)
		}
	}
	drives = trustedDrives
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
				BootPending:  linuxBootPending(d),
			}
			if !info.Orphaned {
				info.BootEvidence, _ = installedLinuxEvidence(d)
				info.Deployed = info.BootEvidence != nil
				info.BootPending = info.BootPending && !info.Deployed
			}
			if d != "C" {
				fillDedicatedPartitionInfo(&info, d)
				if info.OnDedicatedVol {
					info.VolumeLabel = DedicatedVolumeLabel
				}
			}
			return info
		}
	}

	// 2. No root.disk found, but installation outputs can survive an
	// interrupted attempt. A pre-staged offline bundle is not an attempt.
	for _, d := range drives {
		wootcPath := d + `:\wootc`
		if hasInstallAttempt(wootcPath) {
			info := UninstallInfo{
				Found:        true,
				StorageDrive: d,
				Orphaned:     true,
			}

			if d != "C" {
				fillDedicatedPartitionInfo(&info, d)
				if info.OnDedicatedVol {
					info.VolumeLabel = DedicatedVolumeLabel
				}
			}
			return info
		}
	}

	// 3. Check for a dedicated wootc-data volume even if \wootc was hand-deleted.
	for _, dp := range listDataPartitions() {
		if strings.EqualFold(dp.Label, DedicatedVolumeLabel) {
			info := UninstallInfo{Found: true, StorageDrive: dp.Letter, Orphaned: true, VolumeLabel: dp.Label}
			fillDedicatedPartitionInfo(&info, dp.Letter)
			return info
		}
	}

	// 4. Check for system-wide wootc artifacts (BCD entries, ESP files, or registry).
	hasBCD, bcdErr := hasWootcBCDEntry()
	if hasBCD || bcdErr != nil || hasWootcESPArtifacts() || hasUninstallRegistryEntry() {
		return UninstallInfo{Found: true, StorageDrive: "C", Orphaned: true}
	}

	return UninstallInfo{Found: false}
}

// hasWootcBCDEntry reports whether BCD contains any wootc firmware entry or
// active one-shot bootsequence pointing to wootc.
func hasWootcBCDEntry() (bool, error) {
	objs, err := observeFirmware(bootChainEnv{
		bcdedit: func(args ...string) (string, error) { return runCmd("bcdedit", args...) },
	})
	if err != nil {
		return false, err
	}
	return len(wootcEntryIDs(objs, "")) != 0, nil
}

// hasWootcESPArtifacts reports whether the ESP contains any wootc-owned files
// or directories.
func hasWootcESPArtifacts() bool {
	espPath, err := findESP()
	if err != nil {
		return false
	}
	defer releaseESPLetter()
	owned, err := hasESPOwnedFiles(espPath)
	// An unreadable or unsafe ownership record is unresolved cleanup evidence.
	return owned || err != nil
}

// hasUninstallRegistryEntry reports whether the Add/Remove Programs key exists.
func hasUninstallRegistryEntry() bool {
	out, err := runPowerShellOutput(fmt.Sprintf(
		`$ErrorActionPreference='Stop'; if (Test-Path -LiteralPath %s) { Write-Output 'EXISTS' }`, powershellLiteral(uninstallRegKey)))
	return err != nil || strings.TrimSpace(out) == "EXISTS"
}

// cleanupESP deletes only attributable regular files, preserving neighbours.
func cleanupESP() error {
	espPath, err := findESP()
	if err != nil {
		return fmt.Errorf("locate EFI boot partition for cleanup: %w", err)
	}
	defer releaseESPLetter()
	return cleanupESPOwnedFiles(espPath)
}

// deployHasCompleted requires an observed installed Linux boot whose identity
// matches this installation and the current Windows host volume and ESP.
func deployHasCompleted(drive string) bool {
	_, err := installedLinuxEvidence(drive)
	return err == nil
}

// The first installed boot is still available before proof exists. This is a
// staging state, not an installed/healthy claim.
func linuxBootPending(drive string) bool {
	s, ok := readStateFrom(filepath.Join(drive+`:\wootc`, "state.json"))
	return ok && (s.State == StateDeployed || s.State == StateHealthy)
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
		return fmt.Errorf("could not arm the one-time %s boot: %w (output: %s)", installedSystemName(), err, out)
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
	var partitionReceipt StoragePartitionReceipt
	if opts.RemovePartition {
		var err error
		partitionReceipt, err = readStoragePartitionReceipt()
		if err != nil {
			return fmt.Errorf("partition removal refused; creation ownership is missing or unsafe: %w", err)
		}
		boundDrive, present, err := createdPartitionLocation(partitionReceipt)
		if err != nil {
			return err
		}
		if err := verifyPartitionRemovalMarker(partitionReceipt, ".complete"); err == nil {
			if present {
				return fmt.Errorf("completed removal identity unexpectedly exists again; preserving partition")
			}
			return clearCompletedStoragePartitionRemoval(partitionReceipt)
		} else if !os.IsNotExist(err) {
			return err
		}
		if !present {
			if err := verifyPartitionRemovalMarker(partitionReceipt, ".deleted"); err != nil {
				return fmt.Errorf("partition absent without recorded prior deletion observation: %w", err)
			}
			// Retry only the pending extension. Never clean a replacement installation.
			if err := removePartitionAndExtendC("", partitionReceipt); err != nil {
				return err
			}
			return clearCompletedStoragePartitionRemoval(partitionReceipt)
		}
		if info.Found && info.StorageDrive != boundDrive {
			return fmt.Errorf("partition receipt identifies a different installation than the selected uninstall")
		}
		drive = boundDrive
		if _, err := assessCreatedPartition(drive, partitionReceipt); err != nil {
			return err
		}
		if err := verifyCompanionInstallerContents(); err != nil {
			return err
		}
		if err := markStoragePartitionRemoval(partitionReceipt); err != nil {
			return fmt.Errorf("record explicit partition removal: %w", err)
		}
	}
	setStorageDrive(drive)

	targetDrives := []string{drive}
	if drive != "C" {
		targetDrives = append(targetDrives, "C")
	}
	for _, d := range targetDrives {
		disk := filepath.Join(d+`:\wootc`, "disks", "root.disk")
		release, err := acquireVMLock(disk)
		if err != nil {
			return err
		}
		defer release()
		if err := verifyVMDiskReleased(disk); err != nil {
			return err
		}
	}

	var errs []string
	if err := verifyUninstallRegistryOwnership(); err != nil {
		return fmt.Errorf("uninstall preserved an unowned Add/Remove Programs key: %w", err)
	}

	// Prove boot rollback before removing the executable recovery path, EFI
	// files, or the journal needed to retry an interrupted cleanup.
	if err := rollbackBootChain(); err != nil {
		return fmt.Errorf("uninstall kept recovery state because boot cleanup could not be verified: %w", err)
	}
	if err := restorePriorPowerState(); err != nil {
		return fmt.Errorf("uninstall kept saved power settings for a retry: %w", err)
	}
	if err := unregisterRecoveryTasks(); err != nil {
		return fmt.Errorf("uninstall refused before deleting install state: %w", err)
	}
	if err := cleanupESP(); err != nil {
		return fmt.Errorf("uninstall kept install state after EFI cleanup failed: %w", err)
	}

	// 3. Remove the install dir, staged files, cache, and logs.
	// Clean both the active storage drive and C: if distinct.
	// The Apps entry runs the staged copy under install\, so step aside first.
	var removedDirs []string
	for _, d := range targetDrives {
		removedDirs = append(removedDirs, d+`:\wootc\install`)
		if opts.DeleteRootDisk || opts.RemovePartition {
			removedDirs = append(removedDirs, d+`:\wootc`)
		}
	}
	if err := moveRunningImageAside(removedDirs); err != nil {
		return err
	}
	for _, d := range targetDrives {
		if opts.RemovePartition {
			// Target files stay intact until the partition's final contents audit.
			// Companion cleanup removes exact files and empty directories only.
			if d == "C" {
				if err := cleanupCompanionInstallerFiles(); err != nil {
					errs = append(errs, err.Error())
				}
			}
			continue
		}
		wDir := d + `:\wootc`
		if _, err := os.Stat(wDir); err != nil {
			if !os.IsNotExist(err) {
				errs = append(errs, fmt.Sprintf("inspect %s: %v", wDir, err))
			}
			continue
		}
		// Scrub the staged credentials first (#279, #281): RemoveAll only
		// unlinks them, and NTFS keeps a deleted file's clusters readable.
		if failed := scrubInstallSecrets(filepath.Join(wDir, "install")); len(failed) > 0 {
			errs = append(errs, fmt.Sprintf("could not scrub %v", failed))
			continue // Never unlink a secret whose overwrite was not confirmed.
		}
		// The first-boot record vouches for this install; it goes first, so a
		// partial RemoveAll below can never leave it describing a removed one.
		if err := os.Remove(firstBootEvidencePath(wDir)); err != nil && !os.IsNotExist(err) {
			errs = append(errs, err.Error())
			continue
		}
		// Always remove install, bundle, cache, logs, state.json, and metadata
		for _, sub := range []string{"install", "bundle", "cache", "logs"} {
			if err := os.RemoveAll(filepath.Join(wDir, sub)); err != nil {
				errs = append(errs, err.Error())
			}
		}
		for _, loose := range []string{"state.json", "channel.txt", "brand.css", "brand.json", "e2e-drive.json", "e2e-drive-state.json"} {
			if err := os.Remove(filepath.Join(wDir, loose)); err != nil && !os.IsNotExist(err) {
				errs = append(errs, err.Error())
			}
		}

		// Absence of root.disk is not authority to recursively delete other
		// saved VM/user files. Default removal clears only empty directories.
		if opts.DeleteRootDisk || opts.RemovePartition {
			if err := os.RemoveAll(filepath.Join(wDir, "disks")); err != nil {
				errs = append(errs, err.Error())
			}
			if len(errs) == 0 {
				if err := os.RemoveAll(wDir); err != nil {
					errs = append(errs, err.Error())
				}
			}
		} else {
			for _, dir := range []string{filepath.Join(wDir, "disks"), wDir} {
				if err := removeEmptyInstallerDirectory(dir); err != nil {
					errs = append(errs, err.Error())
				}
			}
		}
	}

	// 4. Optionally remove a wootc-created data partition and extend C:.
	if opts.RemovePartition && len(errs) == 0 {
		if err := removePartitionAndExtendC(drive, partitionReceipt); err != nil {
			errs = append(errs, fmt.Sprintf("removing data partition %s: %v", drive, err))
		}
	}
	if len(errs) == 0 {
		if err := unregisterUninstallEntry(); err != nil {
			errs = append(errs, err.Error())
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
	if opts.RemovePartition {
		return clearCompletedStoragePartitionRemoval(partitionReceipt)
	}
	return nil
}

// verifyUninstallClean inspects the system to ensure that all wootc-owned
// boot entries, ESP files, registry keys, and directories were removed.
func verifyUninstallClean(opts UninstallOptions, storageDrive string) []string {
	var errs []string

	if present, err := hasWootcBCDEntry(); err != nil {
		errs = append(errs, "could not verify firmware boot-entry cleanup: "+err.Error())
	} else if present {
		errs = append(errs, "the "+productName()+" firmware boot entry is still present")
	}

	if hasWootcESPArtifacts() {
		errs = append(errs, productName()+" boot files are still present on the EFI system partition")
	}

	if hasUninstallRegistryEntry() {
		errs = append(errs, "Add/Remove Programs registry entry is still present")
	}

	for _, d := range []string{storageDrive, "C"} {
		installPath := d + `:\wootc\install`
		if _, err := os.Stat(installPath); err == nil {
			errs = append(errs, fmt.Sprintf("%s was not removed", installPath))
		} else if !os.IsNotExist(err) {
			errs = append(errs, fmt.Sprintf("could not verify %s was removed: %v", installPath, err))
		}
		if evidence := firstBootEvidencePath(d + `:\wootc`); pathExists(evidence) {
			errs = append(errs, fmt.Sprintf("%s was not removed", evidence))
		}
	}

	if opts.DeleteRootDisk || opts.RemovePartition {
		for _, d := range []string{storageDrive, "C"} {
			wDir := d + `:\wootc`
			if _, err := os.Stat(wDir); err == nil {
				errs = append(errs, fmt.Sprintf("%s was not fully removed", wDir))
			} else if !os.IsNotExist(err) {
				errs = append(errs, fmt.Sprintf("could not verify %s was removed: %v", wDir, err))
			}
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

// Registry metadata is authority for restoring power settings and executing
// uninstall. Never overwrite or remove a same-name key belonging to anything
// else, including old unmarked metadata that cannot prove ownership.
func uninstallRegistryOwnershipScript(create bool) string {
	guard := fmt.Sprintf(`$ErrorActionPreference='Stop'; if (Test-Path -LiteralPath %s) { `+
		`$owner = (Get-ItemProperty -LiteralPath %s -ErrorAction Stop).WootcOwner; `+
		`if ($owner -cne 'wootc-install-v1') { throw 'Unowned Add/Remove Programs key; preserve it and resolve ownership before retrying' } }`,
		powershellLiteral(uninstallRegKey), powershellLiteral(uninstallRegKey))
	if create {
		guard += fmt.Sprintf(` else { New-Item -Path %s -ErrorAction Stop | Out-Null; `+
			`Set-ItemProperty -LiteralPath %s -Name WootcOwner -Value 'wootc-install-v1' -ErrorAction Stop }; `,
			powershellLiteral(uninstallRegKey), powershellLiteral(uninstallRegKey))
	} else {
		guard += "; "
	}
	return guard
}

func verifyUninstallRegistryOwnership() error {
	return runPowerShell(uninstallRegistryOwnershipScript(false))
}

func registerUninstallEntry() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	// The entry runs the staged copy under install\ (see uninstallEntryTarget),
	// never a download or a preview package that can disappear first.
	target := uninstallEntryTarget(filepath.Join(wootcDir(), "install", stagedEngineName), exe,
		func(p string) bool { st, err := os.Stat(p); return err == nil && st.Mode().IsRegular() })
	// uninstallDisplayName (branding_policy.go) owns the listing name.
	values := uninstallEntryValues(effectiveBranding(), target, wootcDir())
	// Brand names may contain quotes; reuse the PowerShell literal encoder.
	quote := powershellLiteral
	script := uninstallRegistryOwnershipScript(true)
	for name, value := range values {
		script += "Set-ItemProperty -Path " + quote(uninstallRegKey) + " -Name " + quote(name) + " -Value " + quote(value) + "; "
	}
	script += "Set-ItemProperty -Path " + quote(uninstallRegKey) + " -Name NoModify -Value 1 -Type DWord; "
	script += "Set-ItemProperty -Path " + quote(uninstallRegKey) + " -Name NoRepair -Value 1 -Type DWord"
	return runPowerShell(script)
}

// moveRunningImageAside renames this program out of a directory uninstall is
// about to delete. Windows refuses to delete a running image but allows it to
// be renamed on the same volume; the renamed file is deleted at the next
// restart.
func moveRunningImageAside(removed []string) error {
	self, err := os.Executable()
	if err != nil || !uninstallRemovesImage(self, removed) {
		return nil
	}
	volume := filepath.VolumeName(self)
	dir := os.TempDir()
	if !strings.EqualFold(filepath.VolumeName(dir), volume) {
		dir = volume + `\`
	}
	aside := filepath.Join(dir, fmt.Sprintf("%s-uninstall-%d.exe", strings.TrimSuffix(stagedEngineName, ".exe"), os.Getpid()))
	if err := os.Rename(self, aside); err != nil {
		return fmt.Errorf("could not move the running uninstaller %s out of the install directory: %w", self, err)
	}
	if p, err := windows.UTF16PtrFromString(aside); err == nil {
		_ = windows.MoveFileEx(p, nil, windows.MOVEFILE_DELAY_UNTIL_REBOOT)
	}
	return nil
}

func unregisterUninstallEntry() error {
	return runPowerShell(uninstallRegistryOwnershipScript(false) + fmt.Sprintf(
		`if (Test-Path -LiteralPath %s) { Remove-Item -LiteralPath %s -Recurse -Force }; if (Test-Path -LiteralPath %s) { throw 'Uninstall registry entry remains' }`,
		powershellLiteral(uninstallRegKey), powershellLiteral(uninstallRegKey), powershellLiteral(uninstallRegKey)))
}

// ── Reboot ────────────────────────────────────────────────────────────────────

func rebootWindows() error {
	_, err := runCmd("shutdown", "/r", "/t", "5", "/f",
		"/c", rebootMessage(effectiveBranding()))
	return err
}

// ── Interactive user derivation (over-the-shoulder UAC) ───────────────────────

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
