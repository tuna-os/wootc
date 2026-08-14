//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
)

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

func setupESP(cfg InstallConfig) error {
	espPath, err := findESP()
	if err != nil {
		return err
	}

	switch cfg.Bootloader {
	case "systemd-boot":
		return setupSystemdBoot(espPath, cfg)
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
	// unless the existing config is ours (reinstall). "Ours" is the shared
	// "# wootc" marker family: the deployer rewrites this file with its
	// Phase-2 menu after every completed deploy, and a reinstall over that
	// state must not be refused as a foreign Linux.
	if data, err := os.ReadFile(grubCfg); err == nil {
		if !strings.Contains(string(data), wootcGrubOwnership) {
			return fmt.Errorf("this PC already has a Linux bootloader at EFI\\fedora — " +
				"installing wootc would break it. Dual-boot alongside an existing " +
				"Linux install is not supported yet")
		}
	}

	// D1b: grub.cfg is not the only file we overwrite (#52). We also drop
	// shimx64.efi and grubx64.efi into EFI\fedora, and a real Fedora/RHEL
	// install owns those binaries even when its grub.cfg lives elsewhere —
	// so the marker check above can pass while we are about to clobber
	// another OS's signed bootloader. Check EVERY destination against a
	// manifest of what wootc itself wrote, and refuse on anything foreign.
	if err := guardESPDestinations(espPath, []string{
		filepath.Join("EFI", "fedora", "shimx64.efi"),
		filepath.Join("EFI", "fedora", "grubx64.efi"),
		filepath.Join("EFI", "wootc", "deployer-vmlinuz"),
		filepath.Join("EFI", "wootc", "deployer-initramfs.img"),
	}); err != nil {
		return err
	}

	// D1c: same collision guard for RHEL-family installs (#52). A machine
	// dual-booting RHEL, CentOS, or Rocky owns EFI\redhat — overwriting its
	// grub.cfg would break that Linux. Mirror the text-marker check from D1
	// so a reinstall over wootc's own redhat config still proceeds.
	redhatGrubCfg := filepath.Join(espPath, "EFI", "redhat", "grub.cfg")
	if data, err := os.ReadFile(redhatGrubCfg); err == nil {
		if !strings.Contains(string(data), wootcGrubOwnership) {
			return fmt.Errorf("this PC already has a Linux bootloader at EFI\\redhat — " +
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
	//
	// Claim each file BEFORE creating it (stageESPFile), never as a batch after
	// the copies. Claiming afterwards left every one of these paths on the ESP
	// unattributed for the seconds its copy took, and whatever read the ESP in
	// that window — a second installer process, or this machine's next attempt
	// after a crash mid-copy — refused the install because wootc's own
	// shimx64.efi looked like another OS's (see app/esp_ownership.go).
	//
	// An ordered slice, not a map: the copy order decided which file was
	// half-written when a concurrent installer looked, so Go's map order was
	// choosing which filename appeared in the refusal from run to run
	// (31081727936 named grubx64.efi, 31160072559 named shimx64.efi). A stable
	// order will not fix a race on its own, but a nondeterministic one makes
	// every report of it look like a different bug.
	for _, s := range []struct{ name, rel string }{
		{"shimx64.efi", filepath.Join("EFI", "fedora", "shimx64.efi")},
		{"grubx64.efi", filepath.Join("EFI", "fedora", "grubx64.efi")},
		{"deployer-vmlinuz", filepath.Join("EFI", "wootc", "deployer-vmlinuz")},
		{"deployer-initramfs.img", filepath.Join("EFI", "wootc", "deployer-initramfs.img")},
	} {
		src := filepath.Join(installDir, s.name)
		if err := stageESPFile(espPath, s.rel, func() error {
			if err := copyFile(src, filepath.Join(espPath, s.rel)); err != nil {
				return fmt.Errorf("copy %s: %w", s.name, err)
			}
			return nil
		}); err != nil {
			return err
		}
	}

	// LUKS type on the cmdline (never the passphrase — that travels in the
	// ACL-restricted vault.json). tpm2-luks auto-unlocks; passphrase mode
	// prompts at boot (SPEC §2.6).
	luks := ""
	if cfg.Encryption != "" && cfg.Encryption != "none" {
		luks = " wootc.luks=" + cfg.Encryption
	}
	// Default to auto: the deployer probes the image and picks the backend
	// definitively (this is the configuration that took dakota/composefs
	// green — run 30710282014). Explicit values are an advanced override.
	installMode := " wootc.bootloader=auto"
	switch cfg.Bootloader {
	case "grub2":
		installMode = " wootc.bootloader=grub2"
	case "systemd-boot":
		installMode = " wootc.bootloader=systemd"
	}
	if cfg.ComposeFS {
		installMode += " wootc.composefs=1"
	}
	// E2E parity with setup-wootc.ps1: the harness diagnoses the deployer
	// from the QEMU SERIAL console. console=ttyS0 sends kernel + deploy logs
	// there (off-screen), which also leaves the VGA free for the deployer's
	// friendly full-screen splash (deploy.sh draws it on /dev/tty1 — the
	// nervous-user reassurance UI, never raw console). Product installs stay
	// clean.
	if os.Getenv("WOOTC_E2E_DRIVE") == "1" {
		installMode += " console=ttyS0"
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
`, wootcGrubMarker, cfg.ImageRef, cfg.Hostname, luks+installMode, cfg.ImageRef, cfg.Hostname, luks+installMode)

	// Same vendor-dir spread as setup-wootc.ps1 (EFI/{fedora,redhat,wootc}):
	// different signed GRUB builds embed different prefixes; covering all
	// three keeps the menu findable regardless of which pair was bundled.
	for _, vendor := range []string{fedoraEFI, filepath.Join(espPath, "EFI", "redhat"), wootcEFI} {
		if err := os.MkdirAll(vendor, 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(vendor, "grub.cfg"), []byte(menu), 0o644); err != nil {
			return fmt.Errorf("write deployer grub.cfg to %s: %w", vendor, err)
		}
	}
	return nil
}

func setupSystemdBoot(espPath string, cfg InstallConfig) error {
	asset, err := systemdBootAsset()
	if err != nil {
		return err
	}
	if on, known := secureBootState(); on || !known {
		if !asset.trustedChain {
			state := "enabled"
			if !known {
				state = "unknown"
			}
			return fmt.Errorf("Secure Boot is %s and the bundled systemd-boot EFI binary is not trusted; choose GRUB2 or disable Secure Boot explicitly", state)
		}
	}

	// D3 guard (#52): a machine with an existing systemd-boot installation
	// owns loader/loader.conf and EFI/systemd/. Overwriting them would break
	// that OS. Refuse unless the existing config is ours (reinstall).
	loaderConf := filepath.Join(espPath, "loader", "loader.conf")
	if data, err := os.ReadFile(loaderConf); err == nil {
		if !strings.Contains(string(data), wootcGrubOwnership) {
			return fmt.Errorf("this PC already has a systemd-boot installation — " +
				"installing wootc would break it. Dual-boot is not supported yet")
		}
	}
	if err := guardESPDestinations(espPath, []string{
		filepath.Join("EFI", "systemd", "shimx64.efi"),
		filepath.Join("EFI", "systemd", "grubx64.efi"),
		filepath.Join("EFI", "systemd", "systemd-bootx64.efi"),
		filepath.Join("EFI", "wootc", "deployer-vmlinuz"),
		filepath.Join("EFI", "wootc", "deployer-initramfs.img"),
	}); err != nil {
		return err
	}

	sdEFI := filepath.Join(espPath, "EFI", "systemd")
	if err := os.MkdirAll(sdEFI, 0o755); err != nil {
		return err
	}
	loaderEntries := filepath.Join(espPath, "loader", "entries")
	if err := os.MkdirAll(loaderEntries, 0o755); err != nil {
		return err
	}
	wootcEFI := filepath.Join(espPath, "EFI", "wootc")
	if err := os.MkdirAll(wootcEFI, 0o755); err != nil {
		return err
	}
	installDir := filepath.Join(wootcDir(), "install")

	// EFI\wootc is our own namespace — copy directly.
	for _, name := range []string{"deployer-vmlinuz", "deployer-initramfs.img"} {
		if err := copyFile(filepath.Join(installDir, name), filepath.Join(wootcEFI, name)); err != nil {
			return fmt.Errorf("stage %s: %w", name, err)
		}
	}

	// EFI\systemd is a shared vendor directory. Stage through the ownership
	// guard so the manifest is written before the file (#52).
	if asset.trustedChain {
		// Debian shim's built-in next-stage filename is grubx64.efi. The
		// Debian-signed systemd-boot binary is deliberately staged under that
		// name so shim verifies it with its embedded Debian certificate.
		for _, s := range []struct{ src, rel string }{
			{asset.shim, filepath.Join("EFI", "systemd", "shimx64.efi")},
			{asset.loader, filepath.Join("EFI", "systemd", "grubx64.efi")},
		} {
			if err := stageESPFile(espPath, s.rel, func() error {
				return copyFile(s.src, filepath.Join(espPath, s.rel))
			}); err != nil {
				return err
			}
		}
	} else {
		rel := filepath.Join("EFI", "systemd", "systemd-bootx64.efi")
		if err := stageESPFile(espPath, rel, func() error {
			return copyFile(asset.loader, filepath.Join(espPath, rel))
		}); err != nil {
			return err
		}
	}
	if err := os.WriteFile(filepath.Join(espPath, "loader", "loader.conf"), []byte("# wootc\ndefault wootc-deployer.conf\ntimeout 5\nconsole-mode keep\n"), 0o644); err != nil {
		return err
	}
	compose := ""
	if cfg.ComposeFS {
		compose = " wootc.composefs=1"
	}
	entry := fmt.Sprintf("title wootc installer\nlinux /EFI/wootc/deployer-vmlinuz\ninitrd /EFI/wootc/deployer-initramfs.img\noptions wootc.image=%s wootc.hostname=%s wootc.vault=/wootc/install/vault.json wootc.bootloader=systemd%s%s quiet\n", cfg.ImageRef, cfg.Hostname, luksCmdline(cfg), compose)
	return os.WriteFile(filepath.Join(loaderEntries, "wootc-deployer.conf"), []byte(entry), 0o644)
}

func luksCmdline(cfg InstallConfig) string {
	if cfg.Encryption == "" || cfg.Encryption == "none" {
		return ""
	}
	return " wootc.luks=" + cfg.Encryption
}

type systemdBootAssets struct {
	loader       string
	shim         string
	trustedChain bool
}

func validAuthenticode(path string) bool {
	quoted := strings.ReplaceAll(path, "'", "''")
	out, err := runPowerShellOutput("(Get-AuthenticodeSignature -LiteralPath '" + quoted + "').Status")
	return err == nil && strings.TrimSpace(out) == "Valid"
}

func systemdBootAsset() (systemdBootAssets, error) {
	exe, _ := os.Executable()
	roots := []string{filepath.Join(filepath.Dir(exe), "efi"), filepath.Join(wootcDir(), "install")}
	// Secure-Boot chain: Microsoft-trusted Debian shim verifies the
	// Debian-signed systemd-boot next stage. Both must validate locally;
	// the presence of a `.signed` suffix alone is never treated as trust.
	for _, root := range roots {
		shim := filepath.Join(root, "debian", "shimx64.efi")
		loader := filepath.Join(root, "debian", "systemd-bootx64.efi.signed")
		if _, err := os.Stat(shim); err != nil {
			continue
		}
		if _, err := os.Stat(loader); err != nil {
			continue
		}
		if validAuthenticode(shim) && validAuthenticode(loader) {
			return systemdBootAssets{loader: loader, shim: shim, trustedChain: true}, nil
		}
	}
	candidates := []string{
		filepath.Join(filepath.Dir(exe), "efi", "systemd-bootx64.efi"),
		filepath.Join(wootcDir(), "install", "systemd-bootx64.efi"),
	}
	for _, path := range candidates {
		if _, err := os.Stat(path); err != nil {
			continue
		}
		return systemdBootAssets{loader: path}, nil
	}
	return systemdBootAssets{}, fmt.Errorf("systemd-boot is not bundled; expected efi\\systemd-bootx64.efi beside wootc.exe")
}

// ── BCD configuration ─────────────────────────────────────────────────────────

// backupBCD exports the store to C:\wootc\install\bcd-before.bak so a broken
// boot configuration can be restored with `bcdedit /import`.
//
// Written exactly ONCE. Re-exporting on a reinstall would capture a store that
// already contains wootc's own entries, which is not the state a user wants to
// get back to.
//
// Fails closed: if the store cannot be snapshotted, something is already wrong
// with BCD access — and that is not a condition under which to start editing
// it. Refusing leaves Windows untouched, which is the safe outcome.
func backupBCD() error {
	dst := filepath.Join(wootcDir(), "install", "bcd-before.bak")
	if _, err := os.Stat(dst); err == nil {
		return nil // keep the pristine pre-wootc copy
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return fmt.Errorf("could not create %s for the boot-configuration backup: %w", filepath.Dir(dst), err)
	}
	if out, err := runCmd("bcdedit", "/export", dst); err != nil {
		return fmt.Errorf("could not back up the boot configuration before changing it: %w (output: %s)", err, out)
	}
	return nil
}

func configureBCD(bootloader string) error {
	var efiRelPath string

	switch bootloader {
	case "systemd-boot":
		asset, err := systemdBootAsset()
		if err != nil {
			return err
		}
		if asset.trustedChain {
			efiRelPath = `\EFI\systemd\shimx64.efi`
		} else {
			efiRelPath = `\EFI\systemd\systemd-bootx64.efi`
		}
	default:
		// The signed-shim chain proven by E2E: BCD → shimx64.efi →
		// grubx64.efi (embedded prefix \EFI\fedora) → deployer menu.
		efiRelPath = `\EFI\fedora\shimx64.efi`
	}

	// Snapshot the boot configuration BEFORE touching it. Modifying BCD is the
	// most dangerous thing wootc does to a working Windows install, and the
	// product's whole promise is that the machine stays recoverable. tunic
	// (mikeslattery/tunic), which solves the same install-from-Windows problem,
	// exports BCD before it edits anything; we did not.
	if err := backupBCD(); err != nil {
		return err
	}

	// Idempotency: sweep any wootc entries from earlier runs first, or every
	// retried install piles up another firmware entry (three of them showed
	// up on the first E2E day). Same discovery as uninstall.
	deleteWootcBCDEntries()

	// bcdedit /copy {bootmgr} /d "wootc" — clones the Windows Boot Manager entry,
	// inheriting the ESP device/partition settings, so no drive letter is needed.
	// This is the proven approach from WubiUEFI (millions of users).
	//
	// Retry, and say what the firmware list looked like when it fails (#74).
	// This step failed on 2 of 3 runs of one cell with two different messages,
	// both about the DISPLAY ORDER:
	//     "Illegal operation attempted on a registry key marked for deletion"
	//     "The data area passed to a system call is too small"
	// The first reads as a transient BCD-store state; the second is what
	// bcdedit reports when the firmware boot entry list has grown large.
	//
	// deleteWootcBCDEntries above removes stale entries by GUID but does not
	// repair the display order — leaving dangling references that cause
	// /copy to fail when it internally reads or touches the display order.
	// Repairing the display order before the copy (idempotent /addfirst of
	// {bootmgr}) plus a bounded retry with sweep covers both failure modes.
	var out string
	var err error
	for attempt := 1; attempt <= 3; attempt++ {
		// Repair the display order before each attempt: deleteWootcBCDEntries
		// above (and between attempts below) can leave dangling GUID refs.
		runCmd("bcdedit", "/displayorder", "{bootmgr}", "/addfirst") //nolint:errcheck
		out, err = runCmd("bcdedit", "/copy", "{bootmgr}", "/d", "wootc")
		if err == nil {
			break
		}
		if attempt < 3 {
			// A partially-created entry from the failed attempt would itself
			// lengthen the list, so sweep before trying again.
			deleteWootcBCDEntries()
			time.Sleep(time.Duration(attempt) * 2 * time.Second)
		}
	}
	if err != nil {
		enum, _ := runCmd("bcdedit", "/enum", "firmware")
		return fmt.Errorf("bcdedit /create: %w (output: %s) — firmware entries at failure: %d\n%s",
			err, out, strings.Count(enum, "identifier"), tail(enum, 2000))
	}

	// Parse the new GUID
	re := regexp.MustCompile(`\{([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\}`)
	m := re.FindStringSubmatch(out)
	if m == nil {
		return fmt.Errorf("could not parse GUID from bcdedit output: %q", out)
	}
	guid := "{" + m[1] + "}"

	// Persist the GUID where setup-wootc.ps1 also records it: the E2E
	// harness schedules the PHASE-2 loopback boot by re-arming exactly this
	// entry (bcd-guid.txt), and uninstall flows read it too. Without it a
	// GUI/headless-armed machine deploys fine but Phase 2 can never be
	// scheduled. Best-effort: BCD itself is already armed at this point.
	if err := os.WriteFile(`C:\wootc\install\bcd-guid.txt`, []byte(guid), 0o644); err != nil {
		fmt.Printf("warning: could not persist bcd-guid.txt: %v\n", err)
	}

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

// tail returns the last n bytes of s, for embedding a bounded slice of a
// command dump in an error without flooding the GUI.
func tail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return "..." + s[len(s)-n:]
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
