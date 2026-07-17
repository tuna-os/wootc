//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
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

	// BitLocker: run manage-bde -status C: and look for "Protection On"
	out, _ := runCmd("manage-bde", "-status", `C:`)
	info.BitLockerOn = strings.Contains(out, "Protection On")

	// Fast Startup: HKLM\...\Power HiberbootEnabled != 0
	info.FastStartupOn = fastStartupEnabled()

	// Secure Boot
	info.SecureBootOn = secureBootEnabled()

	return info
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
	}
	return nil
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

	// Deployer menu at the signed GRUB's embedded prefix.
	menu := fmt.Sprintf(`%s - one-shot Linux installation
set default=0
set timeout=5

menuentry "Install wootc (automatic)" {
    linux /EFI/wootc/deployer-vmlinuz wootc.image=%s wootc.hostname=%s wootc.vault=/wootc/install/vault.json quiet
    initrd /EFI/wootc/deployer-initramfs.img
}

menuentry "Install wootc (debug)" {
    linux /EFI/wootc/deployer-vmlinuz wootc.image=%s wootc.hostname=%s wootc.vault=/wootc/install/vault.json wootc.debug
    initrd /EFI/wootc/deployer-initramfs.img
}
`, wootcGrubMarker, cfg.ImageRef, cfg.Hostname, cfg.ImageRef, cfg.Hostname)

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
	// 1. Remove all wootc BCD entries
	deleteWootcBCDEntries()

	// 2. Remove ESP files. EFI\fedora is only removed when its grub.cfg
	// carries the wootc marker — never touch a real distro's chain.
	espPath, err := findESP()
	if err == nil {
		os.RemoveAll(filepath.Join(espPath, "EFI", "wootc")) //nolint:errcheck
		grubCfg := filepath.Join(espPath, "EFI", "fedora", "grub.cfg")
		if data, err := os.ReadFile(grubCfg); err == nil && strings.Contains(string(data), wootcGrubMarker) {
			os.RemoveAll(filepath.Join(espPath, "EFI", "fedora")) //nolint:errcheck
		}
	}

	// 3. Remove C:\wootc\install\ (NOT root.vhdx — user deletes that manually)
	os.RemoveAll(filepath.Join(wootcDir(), "install")) //nolint:errcheck

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
func wootcDir() string { return `C:\wootc` }
