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

// createRootDisk creates a sparse file of the requested size using native
// Windows APIs (no data written, no zeroing — NTFS allocates on demand).
func createRootDisk(sizeGB int) error {
	path := filepath.Join(wootcDir(), "disks", "root.disk")
	if _, err := os.Stat(path); err == nil {
		return nil // already exists
	}

	pathPtr, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}

	h, err := windows.CreateFile(
		pathPtr,
		windows.GENERIC_WRITE,
		0, nil,
		windows.CREATE_NEW,
		windows.FILE_ATTRIBUTE_NORMAL|windows.FILE_FLAG_SEQUENTIAL_SCAN,
		0,
	)
	if err != nil {
		return fmt.Errorf("CreateFile: %w", err)
	}
	defer windows.CloseHandle(h) //nolint:errcheck

	// Mark sparse
	var dummy uint32
	if err := windows.DeviceIoControl(h, windows.FSCTL_SET_SPARSE, nil, 0, nil, 0, &dummy, nil); err != nil {
		// Non-fatal: FAT32 or unsupported FS. Fall through.
		_ = err
	}

	// Set file size (no data written)
	size := int64(sizeGB) * 1024 * 1024 * 1024
	lo := uint32(size & 0xFFFFFFFF)
	hi := int32(size >> 32)
	if _, err := windows.SetFilePointer(h, int32(lo), &hi, windows.FILE_BEGIN); err != nil {
		return fmt.Errorf("SetFilePointer: %w", err)
	}
	kernel32 := windows.NewLazySystemDLL("kernel32.dll")
	setEOF := kernel32.NewProc("SetEndOfFile")
	r, _, le := setEOF.Call(uintptr(h))
	if r == 0 {
		return fmt.Errorf("SetEndOfFile: %w", le)
	}

	return nil
}

// ── Deployer download ─────────────────────────────────────────────────────────

const deployerBaseURL = "https://github.com/tuna-os/wootc/releases/latest/download/"

func downloadDeployer(ctx context.Context, progress func(float64)) error {
	installDir := filepath.Join(wootcDir(), "install")
	files := []string{"deployer-vmlinuz", "deployer-initramfs.img", "wubildr.efi"}

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

func setupESP(bootloader string) error {
	espPath, err := findESP()
	if err != nil {
		return err
	}

	switch bootloader {
	case "systemd-boot":
		return setupSystemdBoot(espPath)
	default:
		return setupGRUB2(espPath)
	}
}

func setupGRUB2(espPath string) error {
	wootcEFI := filepath.Join(espPath, "EFI", "wootc")
	if err := os.MkdirAll(wootcEFI, 0o755); err != nil {
		return err
	}

	installDir := filepath.Join(wootcDir(), "install")

	// Copy GRUB EFI binaries if available
	for _, name := range []string{"wubildr.efi"} {
		src := filepath.Join(installDir, name)
		dst := filepath.Join(wootcEFI, name)
		if _, err := os.Stat(src); err == nil {
			if err := copyFile(src, dst); err != nil {
				return fmt.Errorf("copy %s: %w", name, err)
			}
		}
	}

	// Copy GRUB configs
	for _, name := range []string{"wubildr.cfg", "grub.install.cfg"} {
		src := filepath.Join(installDir, name)
		dst := filepath.Join(wootcEFI, name)
		if _, err := os.Stat(src); err == nil {
			if err := copyFile(src, dst); err != nil {
				return fmt.Errorf("copy %s: %w", name, err)
			}
		}
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
	espPath, err := findESP()
	if err != nil {
		return err
	}

	// Extract drive letter from path like "S:\"
	espDrive := string([]rune(espPath)[0])
	var efiRelPath string

	switch bootloader {
	case "systemd-boot":
		efiRelPath = `\EFI\systemd\systemd-bootx64.efi`
	default:
		efiRelPath = `\EFI\wootc\wubildr.efi`
	}

	// bcdedit /copy {bootmgr} /d "wootc" — clones the Windows Boot Manager entry,
	// inheriting device/partition settings. We then change the path to our EFI binary.
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

	cmds := [][]string{
		{"bcdedit", "/set", guid, "path", efiRelPath},
		{"bcdedit", "/set", "{fwbootmgr}", "displayorder", guid, "/addfirst"},
		{"bcdedit", "/set", "{fwbootmgr}", "bootsequence", guid, "/addfirst"},
	}
	for _, args := range cmds {
		if out, err := runCmd(args[0], args[1:]...); err != nil {
			return fmt.Errorf("bcdedit %v: %w (output: %s)", args[1:], err, out)
		}
	}
	return nil
}

// ── Uninstall ─────────────────────────────────────────────────────────────────

func uninstall(ctx context.Context) error {
	// 1. Find and remove BCD entry
	out, _ := runCmd("bcdedit", "/enum", "firmware")
	re := regexp.MustCompile(`(?m)description\s+wootc\s*\n.*identifier\s+(\{[^}]+\})`)
	if m := re.FindStringSubmatch(out); m != nil {
		runCmd("bcdedit", "/delete", m[1]) //nolint:errcheck
	}

	// 2. Remove ESP files
	espPath, err := findESP()
	if err == nil {
		os.RemoveAll(filepath.Join(espPath, "EFI", "wootc")) //nolint:errcheck
	}

	// 3. Remove C:\wootc\install\ (NOT root.disk — user deletes that manually)
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
