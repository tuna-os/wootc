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
	info.SecureBootOn = secureBootEnabled()

	// Advisory NTFS fragmentation analysis (SPEC §3.6). Failure to analyze
	// must not block installation.
	info.DefragRecommended = defragRecommended(`C:`)

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
	out, err := runCmd("powershell", "-NoProfile", "-NonInteractive",
		"-Command", "Confirm-SecureBootUEFI 2>$null; $?")
	if err != nil {
		return false
	}
	return strings.TrimSpace(out) == "True"
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

// ── Fast Startup ──────────────────────────────────────────────────────────────

func disableFastStartup() error {
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

// ── Sparse file creation ──────────────────────────────────────────────────────

// createRootDisk creates a dynamic VHDX of the requested virtual capacity.
// DiskPart is part of supported Windows editions and creates a VHDX that is
// natively attachable in Disk Management while allocating sparsely on NTFS.
func createRootDisk(sizeGB int) error {
	path := filepath.Join(wootcDir(), "disks", "root.vhdx")
	if _, err := os.Stat(path); err == nil {
		return nil // already exists
	}

	script, err := os.CreateTemp(filepath.Dir(path), "create-root-vhdx-*.txt")
	if err != nil {
		return fmt.Errorf("create DiskPart script: %w", err)
	}
	scriptPath := script.Name()
	defer os.Remove(scriptPath) //nolint:errcheck
	commands := fmt.Sprintf("create vdisk file=\"%s\" maximum=%d type=expandable\r\n", path, sizeGB*1024)
	if _, err := script.WriteString(commands); err != nil {
		_ = script.Close()
		return fmt.Errorf("write DiskPart script: %w", err)
	}
	if err := script.Close(); err != nil {
		return fmt.Errorf("close DiskPart script: %w", err)
	}

	out, err := exec.Command("diskpart.exe", "/s", scriptPath).CombinedOutput()
	if err != nil {
		return fmt.Errorf("DiskPart create dynamic VHDX: %w: %s", err, strings.TrimSpace(string(out)))
	}
	if _, err := os.Stat(path); err != nil {
		return fmt.Errorf("DiskPart did not create %s: %w", path, err)
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

	// Fetch the published SHA256SUMS manifest so freshly downloaded files
	// can be verified (SPEC §3.1). Best-effort fetch, fail-closed verify:
	// if the manifest is present a hash mismatch aborts the install; if the
	// manifest is unreachable (offline / pre-staged E2E), we proceed without
	// it rather than blocking a locally-provisioned run.
	sums := fetchChecksums(ctx)

	for i, name := range files {
		dest := filepath.Join(installDir, name)
		if _, err := os.Stat(dest); err == nil {
			progress(float64(i+1) / float64(len(files)))
			continue
		}
		if err := downloadFile(ctx, deployerBaseURL+name, dest, func(p float64) {
			base := float64(i) / float64(len(files))
			progress(base + p/float64(len(files)))
		}); err != nil {
			return fmt.Errorf("download %s: %w", name, err)
		}
		// Verify freshly downloaded files against the manifest (fail-closed).
		if want, ok := sums[name]; ok {
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
	}
	return nil
}

// fetchChecksums downloads and parses the release SHA256SUMS manifest into
// a filename→hash map. Returns nil (no verification) if unreachable.
func fetchChecksums(ctx context.Context) map[string]string {
	tmp := filepath.Join(os.TempDir(), "wootc-SHA256SUMS")
	if err := downloadFile(ctx, deployerBaseURL+"SHA256SUMS", tmp, func(float64) {}); err != nil {
		return nil
	}
	defer os.Remove(tmp) //nolint:errcheck
	data, err := os.ReadFile(tmp)
	if err != nil {
		return nil
	}
	sums := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) == 2 {
			// coreutils format: "<hash>  <name>" (name may have a * prefix).
			sums[strings.TrimPrefix(f[1], "*")] = f[0]
		}
	}
	return sums
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

// ── GRUB config ───────────────────────────────────────────────────────────────

func writeGrubConfig(cfg InstallConfig) error {
	installDir := filepath.Join(wootcDir(), "install")

	grubInstall := fmt.Sprintf(`# wootc first-boot installer menu
set default=0
set timeout=5

menuentry "Install wootc (automatic)" {
    linux /wootc/install/deployer-vmlinuz wootc.image=%s wootc.hostname=%s wootc.vault=/wootc/install/vault.json quiet
    initrd /wootc/install/deployer-initramfs.img
}

menuentry "Install wootc (debug)" {
    linux /wootc/install/deployer-vmlinuz wootc.image=%s wootc.hostname=%s wootc.vault=/wootc/install/vault.json wootc.debug
    initrd /wootc/install/deployer-initramfs.img
}
`, cfg.ImageRef, cfg.Hostname, cfg.ImageRef, cfg.Hostname)

	if err := os.WriteFile(filepath.Join(installDir, "grub.install.cfg"), []byte(grubInstall), 0o644); err != nil {
		return err
	}

	// Write wubildr.cfg — the main dual-mode GRUB config (embedded in binary)
	wubildrCfg, err := platformAssets.ReadFile("grub/wubildr.cfg")
	if err != nil {
		return fmt.Errorf("read embedded wubildr.cfg: %w", err)
	}
	if err := os.WriteFile(filepath.Join(installDir, "wubildr.cfg"), wubildrCfg, 0o644); err != nil {
		return fmt.Errorf("write wubildr.cfg: %w", err)
	}

	// Write wubildr-bootstrap.cfg — GRUB entry point from Windows Boot Manager
	bootstrapCfg, err := platformAssets.ReadFile("grub/wubildr-bootstrap.cfg")
	if err != nil {
		return fmt.Errorf("read embedded wubildr-bootstrap.cfg: %w", err)
	}
	if err := os.WriteFile(filepath.Join(installDir, "wubildr-bootstrap.cfg"), bootstrapCfg, 0o644); err != nil {
		return fmt.Errorf("write wubildr-bootstrap.cfg: %w", err)
	}

	return nil
}

// ── ESP setup ─────────────────────────────────────────────────────────────────

// wootcGrubMarker identifies a grub.cfg written by wootc, so reinstalls
// can overwrite it while a real Linux distro's config is protected.
const wootcGrubMarker = "# wootc deployer"

func setupESP(cfg InstallConfig) error {
	espPath, err := findESP()
	if err != nil {
		return err
	}

	switch cfg.Bootloader {
	case "systemd-boot":
		return setupSystemdBoot(espPath)
	default:
		return setupSignedChain(espPath, cfg)
	}
}

// setupSignedChain stages the E2E-proven Secure Boot chain:
// BCD → EFI\fedora\shimx64.efi (MS-signed) → grubx64.efi (embedded prefix
// \EFI\fedora) → grub.cfg → deployer kernel+initramfs on the ESP (the
// signed GRUB cannot read NTFS, so the pair must live on FAT32).
func setupSignedChain(espPath string, cfg InstallConfig) error {
	installDir := filepath.Join(wootcDir(), "install")
	fedoraEFI := filepath.Join(espPath, "EFI", "fedora")
	wootcEFI := filepath.Join(espPath, "EFI", "wootc")
	grubCfg := filepath.Join(fedoraEFI, "grub.cfg")

	// D1 guard: a machine dual-booting a real Fedora-family install owns
	// EFI\fedora — overwriting its grub.cfg would break that Linux. Refuse
	// unless the existing config is ours (reinstall).
	if data, err := os.ReadFile(grubCfg); err == nil {
		if !strings.Contains(string(data), wootcGrubMarker) {
			return fmt.Errorf("this PC already has a Linux bootloader at EFI\\fedora — " +
				"installing wootc would break it. Dual-boot alongside an existing " +
				"Linux install is not supported yet")
		}
	}

	// D2 gate: the deployer pair must fit on the ESP. Measure before
	// copying so the failure is a clear sentence, not a mid-copy ENOSPC.
	var need int64
	for _, name := range []string{"deployer-vmlinuz", "deployer-initramfs.img", "shimx64.efi", "grubx64.efi"} {
		st, err := os.Stat(filepath.Join(installDir, name))
		if err != nil {
			return fmt.Errorf("%s is missing from %s — the download step did not complete: %w", name, installDir, err)
		}
		need += st.Size()
	}
	var freeBytes uint64
	espPtr, _ := syscall.UTF16PtrFromString(espPath)
	if err := windows.GetDiskFreeSpaceEx(espPtr, &freeBytes, nil, nil); err == nil {
		const slack = 4 << 20
		if int64(freeBytes) < need+slack {
			return fmt.Errorf("the EFI system partition is too small: it has %d MB free but the "+
				"Linux starter needs %d MB. This PC's boot partition cannot hold wootc",
				freeBytes>>20, (need+slack)>>20)
		}
	}

	for _, dir := range []string{fedoraEFI, wootcEFI} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}

	// Signed chain into EFI\fedora, deployer pair into EFI\wootc.
	for src, dst := range map[string]string{
		filepath.Join(installDir, "shimx64.efi"):            filepath.Join(fedoraEFI, "shimx64.efi"),
		filepath.Join(installDir, "grubx64.efi"):            filepath.Join(fedoraEFI, "grubx64.efi"),
		filepath.Join(installDir, "deployer-vmlinuz"):       filepath.Join(wootcEFI, "deployer-vmlinuz"),
		filepath.Join(installDir, "deployer-initramfs.img"): filepath.Join(wootcEFI, "deployer-initramfs.img"),
	} {
		if err := copyFile(src, dst); err != nil {
			return fmt.Errorf("copy %s: %w", filepath.Base(src), err)
		}
	}

	// LUKS type on the cmdline (never the passphrase — that travels in the
	// ACL-restricted vault.json). tpm2-luks auto-unlocks; passphrase mode
	// prompts at boot (SPEC §2.6).
	luks := ""
	if cfg.Encryption != "" && cfg.Encryption != "none" {
		luks = " wootc.luks=" + cfg.Encryption
	}

	// Deployer menu at the signed GRUB's embedded prefix.
	menu := fmt.Sprintf(`%s - one-shot Linux installation
set default=0
set timeout=5

menuentry "Install wootc (automatic)" {
    linux /EFI/wootc/deployer-vmlinuz wootc.image=%s wootc.hostname=%s wootc.vault=/wootc/install/vault.json%s quiet
    initrd /EFI/wootc/deployer-initramfs.img
}

menuentry "Install wootc (debug)" {
    linux /EFI/wootc/deployer-vmlinuz wootc.image=%s wootc.hostname=%s wootc.vault=/wootc/install/vault.json%s wootc.debug
    initrd /EFI/wootc/deployer-initramfs.img
}
`, wootcGrubMarker, cfg.ImageRef, cfg.Hostname, luks, cfg.ImageRef, cfg.Hostname, luks)

	if err := os.WriteFile(grubCfg, []byte(menu), 0o644); err != nil {
		return fmt.Errorf("write deployer grub.cfg: %w", err)
	}
	return nil
}

func setupSystemdBoot(espPath string) error {
	sdEFI := filepath.Join(espPath, "EFI", "systemd")
	if err := os.MkdirAll(sdEFI, 0o755); err != nil {
		return err
	}
	loaderEntries := filepath.Join(espPath, "loader", "entries")
	if err := os.MkdirAll(loaderEntries, 0o755); err != nil {
		return err
	}
	// TODO: copy systemd-bootx64.efi + write BLS entries
	return nil
}

// ── BCD configuration ─────────────────────────────────────────────────────────

func configureBCD(bootloader string) error {
	var efiRelPath string

	switch bootloader {
	case "systemd-boot":
		efiRelPath = `\EFI\systemd\systemd-bootx64.efi`
	default:
		// The signed-shim chain proven by E2E: BCD → shimx64.efi →
		// grubx64.efi (embedded prefix \EFI\fedora) → deployer menu.
		efiRelPath = `\EFI\fedora\shimx64.efi`
	}

	// Idempotency: sweep any wootc entries from earlier runs first, or every
	// retried install piles up another firmware entry (three of them showed
	// up on the first E2E day). Same discovery as uninstall.
	deleteWootcBCDEntries()

	// bcdedit /copy {bootmgr} /d "wootc" — clones the Windows Boot Manager entry,
	// inheriting the ESP device/partition settings, so no drive letter is needed.
	// This is the proven approach from WubiUEFI (millions of users).
	out, err := runCmd("bcdedit", "/copy", "{bootmgr}", "/d", "wootc")
	if err != nil {
		return fmt.Errorf("bcdedit /create: %w (output: %s)", err, out)
	}

	// Parse the new GUID
	re := regexp.MustCompile(`\{([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\}`)
	m := re.FindStringSubmatch(out)
	if m == nil {
		return fmt.Errorf("could not parse GUID from bcdedit output: %q", out)
	}
	guid := "{" + m[1] + "}"

	// One-shot bootsequence only: nothing permanent changes in the user's
	// boot order until TunaOS is known to work. displayorder promotion is a
	// post-deploy, user-confirmed action, not part of the install.
	cmds := [][]string{
		{"bcdedit", "/set", guid, "path", efiRelPath},
		{"bcdedit", "/set", "{fwbootmgr}", "bootsequence", guid, "/addfirst"},
	}
	for _, args := range cmds {
		if out, err := runCmd(args[0], args[1:]...); err != nil {
			return fmt.Errorf("bcdedit %v: %w (output: %s)", args[1:], err, out)
		}
	}
	return nil
}

// deleteWootcBCDEntries removes every firmware entry named exactly
// "wootc" (identifier precedes description in bcdedit output).
func deleteWootcBCDEntries() {
	out, _ := runCmd("bcdedit", "/enum", "firmware")
	re := regexp.MustCompile(`(?ms)identifier\s+(\{[^}]+\})[^{]*?description\s+wootc\s*$`)
	for _, m := range re.FindAllStringSubmatch(out, -1) {
		runCmd("bcdedit", "/delete", m[1]) //nolint:errcheck
	}
}

// ── Uninstall ─────────────────────────────────────────────────────────────────

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

	// 2. Remove ESP files. EFI\fedora only when its grub.cfg is ours.
	if espPath, err := findESP(); err == nil {
		os.RemoveAll(filepath.Join(espPath, "EFI", "wootc")) //nolint:errcheck
		grubCfg := filepath.Join(espPath, "EFI", "fedora", "grub.cfg")
		if data, err := os.ReadFile(grubCfg); err == nil && strings.Contains(string(data), wootcGrubMarker) {
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

// ── ESP discovery ─────────────────────────────────────────────────────────────

func findESP() (string, error) {
	// Use mountvol to enumerate volumes and find the FAT32 EFI System Partition.
	// Fallback: assign a letter via diskpart if none is assigned.
	script := `
$esp = Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } | Select-Object -First 1
if (-not $esp) {
    $esp = Get-Volume | Where-Object { $_.FileSystemType -eq 'FAT32' -and $_.Size -lt 1GB } | Select-Object -First 1 | Get-Partition
}
if (-not $esp.DriveLetter) {
    $esp | Add-PartitionAccessPath -AssignDriveLetter
    $esp = Get-Partition -DiskNumber $esp.DiskNumber -PartitionNumber $esp.PartitionNumber
}
Write-Output $esp.DriveLetter
`
	out, err := runPowerShellOutput(script)
	if err != nil {
		return "", fmt.Errorf("ESP discovery: %w", err)
	}
	letter := strings.TrimSpace(out)
	if letter == "" || len(letter) != 1 {
		return "", fmt.Errorf("ESP drive letter not found (output: %q)", out)
	}
	return letter + `:\`, nil
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
