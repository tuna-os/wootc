//go:build windows

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// ── System info ───────────────────────────────────────────────────────────────

func getSystemInfo() SystemInfo {
	info := SystemInfo{IsUEFI: isUEFI()}

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

func defragRecommended(vol string) bool {
	out, _ := runCmd("defrag.exe", vol, "/A", "/V")
	return strings.Contains(strings.ToLower(out), "you should defragment this volume")
}

func defragDrive() error {
	out, err := runCmd("defrag.exe", `C:`, "/U", "/V")
	if err != nil {
		return fmt.Errorf("defragmenting C:: %w (output: %s)", err, strings.TrimSpace(out))
	}
	return nil
}

// captureBitLockerRecoveryKey returns the numerical recovery password
// (48 digits) for the given volume, or "" if the volume is not BitLocker
// protected or the key cannot be extracted. The recovery password is used
// from Phase 2 (Linux) to unlock the encrypted C: drive so the User Data
// Bridge can find the user profiles that live there (#61).
func captureBitLockerRecoveryKey(vol string) string {
	// PowerShell: Get-BitLockerVolume -> KeyProtector -> RecoveryPassword.
	out, err := runPowerShellOutput(fmt.Sprintf(
		`$v = Get-BitLockerVolume -MountPoint '%s' -ErrorAction SilentlyContinue; `+
			`if (-not $v -or $v.ProtectionStatus -ne 'On') { exit 0 }; `+
			`$kp = $v.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1; `+
			`if ($kp) { Write-Output $kp.RecoveryPassword }`, vol))
	if err == nil {
		key := strings.TrimSpace(out)
		key = strings.ReplaceAll(key, "-", "")
		if len(key) == 48 {
			return key
		}
	}
	// Fallback: manage-bde text output.
	mb, err := runCmd("manage-bde", "-protectors", "-get", vol)
	if err != nil {
		return ""
	}
	// The numerical password line looks like:
	//   Numerical Password:
	//       ID: {GUID}
	//       Password:
	//           123456-789012-345678-901234-567890-123456-789012-123456
	re := regexp.MustCompile(`(?m)^\s*Password:\s*$\s*^\s*([0-9-]{55})\s*$`)
	m := re.FindStringSubmatch(mb)
	if m == nil {
		return ""
	}
	key := strings.ReplaceAll(m[1], "-", "")
	if len(key) == 48 {
		return key
	}
	return ""
}

// writeBitLockerKey writes the numerical recovery password to
// C:\wootc\install\bitlocker-key.txt on the storage drive, so Phase 2
// can read it and unlock the encrypted C: for profile discovery (#61).
// The file is ACL-restricted (SYSTEM + Administrators only).
func writeBitLockerKey(key string) error {
	keyPath := filepath.Join(wootcDir(), "install", "bitlocker-key.txt")
	if err := os.WriteFile(keyPath, []byte(key+"\n"), 0o600); err != nil {
		return fmt.Errorf("write bitlocker-key.txt: %w", err)
	}
	if err := restrictFileACL(keyPath); err != nil {
		fmt.Fprintf(os.Stderr, "[wootc] warning: ACL restriction failed for bitlocker-key.txt: %v\n", err)
	}
	return nil
}

// bitlockerState classifies a volume's encryption using
// Get-BitLockerVolume: "off" | "on" | "encrypting" | "decrypting".
// Falls back to manage-bde parsing when the cmdlet is unavailable.
func bitlockerState(vol string) string {
	out, err := runPowerShellOutput(fmt.Sprintf(
		`$v = Get-BitLockerVolume -MountPoint '%s' -ErrorAction SilentlyContinue; `+
			`if (-not $v) { 'off' } `+
			`elseif ($v.VolumeStatus -eq 'EncryptionInProgress') { 'encrypting' } `+
			`elseif ($v.VolumeStatus -eq 'DecryptionInProgress') { 'decrypting' } `+
			`elseif ($v.ProtectionStatus -eq 'On') { 'on' } `+
			`else { 'off' }`, vol))
	if err == nil {
		if s := strings.TrimSpace(out); s != "" {
			return s
		}
	}
	// Fallback: manage-bde text.
	mb, _ := runCmd("manage-bde", "-status", vol)
	switch {
	case strings.Contains(mb, "Encryption in Progress"):
		return "encrypting"
	case strings.Contains(mb, "Decryption in Progress"):
		return "decrypting"
	case strings.Contains(mb, "Protection On"):
		return "on"
	default:
		return "off"
	}
}

// listDataPartitions enumerates fixed volumes other than C: with their
// free space and encryption state, as candidates for root.disk when C:
// is BitLocker-protected (SPEC §3.5 manual path).
func listDataPartitions() []DataPartition {
	out, err := runPowerShellOutput(
		`Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.DriveLetter -ne 'C' } | ` +
			`ForEach-Object { $b = (Get-BitLockerVolume -MountPoint ($_.DriveLetter + ':') -ErrorAction SilentlyContinue); ` +
			`'{0}|{1}|{2}|{3}' -f $_.DriveLetter, $_.FileSystemLabel, [math]::Round($_.SizeRemaining/1GB,1), ` +
			`($(if ($b -and $b.ProtectionStatus -eq 'On') {'1'} else {'0'})) }`)
	if err != nil {
		return nil
	}
	var parts []DataPartition
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		f := strings.Split(strings.TrimSpace(line), "|")
		if len(f) != 4 || f[0] == "" {
			continue
		}
		free, _ := strconv.ParseFloat(f[2], 64)
		parts = append(parts, DataPartition{
			Letter: f[0], Label: f[1], FreeGB: free, Encrypted: f[3] == "1",
		})
	}
	return parts
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

// ── Raw root.disk creation ────────────────────────────────────────────────────

// createRootDisk creates the RAW root.disk image the deployer partitions and
// Phase 2 attaches with `losetup --partscan`. Raw replaced VHDX in 8136ae6:
// target bootc images ship losetup but not qemu-nbd, so VHDX forced a
// foreign qemu-nbd + 26-library closure into the Phase-2 initramfs (soname
// mismatches, silent staging deaths, QEMU VHDX-corruption reports). This
// function had not been ported and still made a VHDX no Phase 2 could
// attach (found by the GUI-driven E2E, run 20260723T1144).
//
// Two Windows-specific requirements, mirrored from setup-wootc.ps1:
//   - allocate with SetLength (sparse on NTFS, instant), and
//   - extend the Valid Data Length with `fsutil file setvaliddata` —
//     without it the Linux ntfs3 driver EIOs on every loop0 write past VDL.
func createRootDisk(sizeGB int) error {
	path := filepath.Join(wootcDir(), "disks", "root.disk")
	sizeBytes := int64(sizeGB) * 1024 * 1024 * 1024
	if st, err := os.Stat(path); err == nil && st.Size() == sizeBytes {
		return nil // already exists at the right size
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create disks dir: %w", err)
	}
	_ = os.Remove(path)

	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("create root.disk: %w", err)
	}
	if err := f.Truncate(sizeBytes); err != nil {
		_ = f.Close()
		return fmt.Errorf("allocate root.disk (%d GB): %w", sizeGB, err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("close root.disk: %w", err)
	}

	// setvaliddata needs SeManageVolumePrivilege — held by elevated admins.
	if out, err := runCmd("fsutil", "file", "setvaliddata", path,
		fmt.Sprintf("%d", sizeBytes)); err != nil {
		return fmt.Errorf("fsutil setvaliddata (VDL extension): %w: %s", err, strings.TrimSpace(out))
	}

	st, err := os.Stat(path)
	if err != nil || st.Size() != sizeBytes {
		return fmt.Errorf("root.disk verification failed: got %d bytes, want %d", st.Size(), sizeBytes)
	}
	return nil
}

// ── Deployer download ─────────────────────────────────────────────────────────

const deployerBaseURL = "https://github.com/tuna-os/wootc/releases/latest/download/"

func downloadDeployer(ctx context.Context, progress func(float64)) error {
	installDir := filepath.Join(wootcDir(), "install")
	// The signed shim+grub pair carries the Secure Boot chain; wubildr.efi
	// remains only for the legacy NTFS fallback path.
	files := []string{"deployer-vmlinuz", "deployer-initramfs.img", "shimx64.efi", "grubx64.efi", "wubildr.efi"}

	// The SHA256SUMS manifest is REQUIRED for production boot artifacts (#53).
	// These files become privileged kernel/initramfs/EFI inputs; wootc must
	// never install a boot artifact it cannot verify. This is fail-closed:
	// an unreachable manifest, a missing entry, a corrupt cache, and a
	// checksum mismatch all abort the install.
	sums, err := fetchChecksums(ctx)
	if err != nil {
		return fmt.Errorf("cannot verify boot artifacts: SHA256SUMS manifest unavailable: %w", err)
	}

	for i, name := range files {
		dest := filepath.Join(installDir, name)
		want, inManifest := sums[name]
		if !inManifest {
			return fmt.Errorf("checksum not found in manifest for %s: refusing to install an unverified boot artifact", name)
		}

		// Verify cached file before reuse (#53). A stale or corrupt cache must
		// not be accepted as a privileged boot input.
		if _, statErr := os.Stat(dest); statErr == nil {
			got, hashErr := sha256File(dest)
			if hashErr != nil {
				// Corrupt or unreadable cache — remove and re-download.
				os.Remove(dest) //nolint:errcheck
			} else if strings.EqualFold(got, want) {
				progress(float64(i+1) / float64(len(files)))
				continue
			}
			// Checksum mismatch on cached file — remove and re-download.
			os.Remove(dest) //nolint:errcheck
		}

		if err := downloadFile(ctx, deployerBaseURL+name, dest, func(p float64) {
			base := float64(i) / float64(len(files))
			progress(base + p/float64(len(files)))
		}); err != nil {
			return fmt.Errorf("download %s: %w", name, err)
		}
		// Verify freshly downloaded file against the manifest (fail-closed).
		got, err := sha256File(dest)
		if err != nil {
			return fmt.Errorf("hashing %s: %w", name, err)
		}
		if !strings.EqualFold(got, want) {
			os.Remove(dest) //nolint:errcheck — don't leave a bad artifact
			return fmt.Errorf("checksum mismatch for %s: the download may be corrupt or tampered "+
				"(expected %s, got %s)", name, want[:12], got[:12])
		}
	}
	return nil
}

// fetchChecksums downloads and parses the release SHA256SUMS manifest into
// a filename→hash map. Fail-closed (#53): every error aborts the install
// rather than silently disabling verification of privileged boot artifacts.
func fetchChecksums(ctx context.Context) (map[string]string, error) {
	tmp := filepath.Join(os.TempDir(), "wootc-SHA256SUMS")
	if err := downloadFile(ctx, deployerBaseURL+"SHA256SUMS", tmp, func(float64) {}); err != nil {
		return nil, fmt.Errorf("fetch SHA256SUMS: %w", err)
	}
	defer os.Remove(tmp) //nolint:errcheck
	data, err := os.ReadFile(tmp)
	if err != nil {
		return nil, fmt.Errorf("read SHA256SUMS: %w", err)
	}
	sums := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) == 2 {
			// coreutils format: "<hash>  <name>" (name may have a * prefix).
			sums[strings.TrimPrefix(f[1], "*")] = f[0]
		}
	}
	return sums, nil
}

// sha256File returns the lowercase hex SHA-256 of a file.
func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
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

// dedicatedVolumeInfo reports whether drive d holds only wootc data (so it
// is safe to remove and fold back into C:) and how much space that frees.
func dedicatedVolumeInfo(d string) (bool, float64) {
	// A wootc-created volume is labeled "wootc-data" and contains nothing
	// but the wootc dir (ignoring system folders).
	out, err := runPowerShellOutput(fmt.Sprintf(
		`$items = Get-ChildItem '%s:\' -Force -ErrorAction SilentlyContinue | Where-Object { `+
			`$_.Name -notin @('$RECYCLE.BIN','System Volume Information','wootc') }; `+
			`$v = Get-Volume -DriveLetter %s -ErrorAction SilentlyContinue; `+
			`'{0}|{1}' -f $items.Count, [math]::Round($v.Size/1GB,1)`, d, d))
	if err != nil {
		return false, 0
	}
	f := strings.Split(strings.TrimSpace(out), "|")
	if len(f) != 2 {
		return false, 0
	}
	sizeGB, _ := strconv.ParseFloat(f[1], 64)
	return f[0] == "0", sizeGB
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

// removePartitionAndExtendC deletes the wootc data partition and grows C:
// into the freed space (SPEC §5.2). Only called when the volume is
// confirmed wootc-created and holds no other data.
func removePartitionAndExtendC(drive string) error {
	script := fmt.Sprintf(`
$ErrorActionPreference = 'Stop'
$p = Get-Partition -DriveLetter %s
$disk = $p.DiskNumber
Remove-Partition -DriveLetter %s -Confirm:$false
$supported = Get-PartitionSupportedSize -DriveLetter C
Resize-Partition -DriveLetter C -Size $supported.SizeMax`, drive, drive)
	out, err := runPowerShellOutput(script)
	if err != nil {
		return fmt.Errorf("%w (output: %s)", err, strings.TrimSpace(out))
	}
	return nil
}

// ── Reboot ────────────────────────────────────────────────────────────────────

func rebootWindows() error {
	_, err := runCmd("shutdown", "/r", "/t", "5", "/f",
		"/c", "wootc is rebooting to start the installer")
	return err
}


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

// CreateDataPartition shrinks C: and creates a new unencrypted NTFS
// partition of sizeGB for Linux storage, returning its drive letter.
// C: stays BitLocker-protected — the new volume is created outside the
// encrypted region and holds only root.disk + vault (SPEC §3.5). We never
// decrypt C:. Suspend-BitLocker (RebootCount 1) only relaxes the TPM seal
// so the partition table can be edited; the disk stays encrypted and
// protection auto-resumes on next boot.
func (a *App) CreateDataPartition(sizeGB int) (DataPartition, error) {
	if sizeGB < 20 {
		sizeGB = 20
	}
	script := fmt.Sprintf(`
$ErrorActionPreference = 'Stop'
$c = Get-Partition -DriveLetter C
$bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
if ($bl -and $bl.ProtectionStatus -eq 'On') { Suspend-BitLocker -MountPoint 'C:' -RebootCount 1 | Out-Null }
$supported = Get-PartitionSupportedSize -DriveLetter C
$shrinkBytes = %dGB
$target = $supported.SizeMax - $shrinkBytes
if ($target -lt $supported.SizeMin) { throw 'Not enough free space on C: to shrink by the requested amount' }
Resize-Partition -DriveLetter C -Size $target
$np = New-Partition -DiskNumber $c.DiskNumber -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $np -FileSystem NTFS -NewFileSystemLabel 'wootc-data' -Confirm:$false | Out-Null
$np = Get-Partition -DiskNumber $c.DiskNumber -PartitionNumber $np.PartitionNumber
Write-Output $np.DriveLetter`, sizeGB)

	out, err := runPowerShellOutput(script)
	if err != nil {
		return DataPartition{}, fmt.Errorf("create data partition: %w (output: %s)", err, strings.TrimSpace(out))
	}
	letter := strings.TrimSpace(out)
	if len(letter) != 1 {
		return DataPartition{}, fmt.Errorf("unexpected drive letter from partition creation: %q", out)
	}
	return DataPartition{Letter: letter, Label: "wootc-data", FreeGB: float64(sizeGB), Encrypted: false}, nil
}
