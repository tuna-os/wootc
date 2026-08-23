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
		filepath.Join("EFI", "fedora", "mmx64.efi"),
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
	// mmx64.efi (MokManager) is optional — releases before it shipped have
	// no copy to stage — but without it shim cannot run the MOK enrollment
	// that custom-kernel images (Bazzite, #248) queue during deploy.
	if st, err := os.Stat(filepath.Join(installDir, "mmx64.efi")); err == nil {
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
	for _, s := range []struct {
		name, rel string
		// mmx64.efi (MokManager) rides beside shim so custom-kernel images
		// (Bazzite, #248) can complete the MOK enrollment the deployer
		// queues. Optional: releases before it shipped have no copy, and a
		// non-akmods install never launches it.
		optional bool
	}{
		{"shimx64.efi", filepath.Join("EFI", "fedora", "shimx64.efi"), false},
		{"grubx64.efi", filepath.Join("EFI", "fedora", "grubx64.efi"), false},
		{"mmx64.efi", filepath.Join("EFI", "fedora", "mmx64.efi"), true},
		{"deployer-vmlinuz", filepath.Join("EFI", "wootc", "deployer-vmlinuz"), false},
		{"deployer-initramfs.img", filepath.Join("EFI", "wootc", "deployer-initramfs.img"), false},
	} {
		src := filepath.Join(installDir, s.name)
		if s.optional {
			if _, err := os.Stat(src); err != nil {
				continue
			}
		}
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
	// MOK enrollment is OPT-IN per image (#248): only kernels the Fedora
	// shim cannot verify (Bazzite's fsync) need the one-time MokManager
	// step, and images with Fedora-signed kernels (aurora, bluefin) must
	// never be handed a firmware prompt they do not need. The deployer only
	// queues the enrollment when this flag rides the cmdline.
	if imageNeedsMok(cfg.ImageRef) {
		installMode += " wootc.mok=enroll"
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
	// Retry the WHOLE arm, and say what the firmware list looked like when it
	// fails (#74). The transient BCD-store errors —
	//     "Illegal operation attempted on a registry key marked for deletion"
	//     "The data area passed to a system call is too small"
	// — were first seen on /copy (2 of 3 runs of one cell), so only /copy got
	// the retry. Then bluefin run 32642504000 hit the SAME "marked for
	// deletion" transient on the bootsequence step, which had no protection,
	// and the install died on a one-shot flake. A fresh entry whose registry
	// key has gone bad cannot be repaired by re-running one command against
	// it — the retry must discard it (sweep) and rebuild from /copy. So the
	// loop now wraps copy → parse → path → bootsequence as one attempt.
	//
	// deleteWootcBCDEntries removes stale entries by GUID but does not repair
	// the display order — dangling references make /copy fail when it reads
	// or touches the display order, so each attempt repairs it first
	// (idempotent /addfirst of {bootmgr}).
	re := regexp.MustCompile(`\{([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\}`)
	var out, guid string
	var err error
	for attempt := 1; attempt <= 3; attempt++ {
		guid = ""
		runCmd("bcdedit", "/displayorder", "{bootmgr}", "/addfirst") //nolint:errcheck
		out, err = runCmd("bcdedit", "/copy", "{bootmgr}", "/d", "wootc")
		if err == nil {
			if m := re.FindStringSubmatch(out); m == nil {
				err = fmt.Errorf("could not parse GUID from bcdedit output: %q", out)
			} else {
				guid = "{" + m[1] + "}"
				// One-shot bootsequence only: nothing permanent changes in
				// the user's boot order until TunaOS is known to work.
				// displayorder promotion is a post-deploy, user-confirmed
				// action, not part of the install.
				for _, args := range [][]string{
					{"bcdedit", "/set", guid, "path", efiRelPath},
					{"bcdedit", "/set", "{fwbootmgr}", "bootsequence", guid, "/addfirst"},
				} {
					if out, err = runCmd(args[0], args[1:]...); err != nil {
						err = fmt.Errorf("bcdedit %v: %w (output: %s)", args[1:], err, out)
						break
					}
				}
			}
		}
		if err == nil {
			break
		}
		if attempt < 3 {
			// A partially-created or gone-bad entry from the failed attempt
			// would itself poison the next one, so sweep before retrying.
			deleteWootcBCDEntries()
			time.Sleep(time.Duration(attempt) * 2 * time.Second)
		}
	}
	if err != nil {
		enum, _ := runCmd("bcdedit", "/enum", "firmware")
		return fmt.Errorf("bcdedit arm: %w — firmware entries at failure: %d\n%s",
			err, strings.Count(enum, "identifier"), tail(enum, 2000))
	}

	// Persist the GUID where setup-wootc.ps1 also records it: the E2E
	// harness schedules the PHASE-2 loopback boot by re-arming exactly this
	// entry (bcd-guid.txt), and uninstall flows read it too. Without it a
	// GUI/headless-armed machine deploys fine but Phase 2 can never be
	// scheduled. Best-effort: BCD itself is already armed at this point.
	if err := os.WriteFile(`C:\wootc\install\bcd-guid.txt`, []byte(guid), 0o644); err != nil {
		fmt.Printf("warning: could not persist bcd-guid.txt: %v\n", err)
	}

	// Enforce the bootsequence-only promise: /copy can register the clone in
	// the permanent firmware displayorder too (position varies by firmware),
	// and an entry there outlives the one-shot — after the deploy the machine
	// would boot Linux by default instead of returning to Windows. Removing
	// it from displayorder leaves the entry itself (and the bootsequence
	// pointing at it) intact. Best-effort: firmwares that never added it
	// report a harmless error here.
	runCmd("bcdedit", "/set", "{fwbootmgr}", "displayorder", guid, "/remove") //nolint:errcheck
	return nil
}

// disarmOneShot undoes the boot arming after a cancelled or failed install.
// Without it, a user who cancelled at 82% — or whose install failed at
// "Saving your settings" — still had a live one-shot pointing at a
// half-configured deployer, and got a surprise Linux boot attempt on their
// next restart while the UI told them "nothing permanent changes". The
// deployer's own failure path returns safely to Windows either way, so this
// is about keeping the promise, not about safety. Best-effort by design:
// every command is harmless when the thing it removes is already gone.
func disarmOneShot() {
	runCmd("bcdedit", "/deletevalue", "{fwbootmgr}", "bootsequence") //nolint:errcheck
	guidPath := filepath.Join(wootcDir(), "install", "bcd-guid.txt")
	if b, err := os.ReadFile(guidPath); err == nil {
		if g := strings.TrimSpace(string(b)); strings.HasPrefix(g, "{") {
			runCmd("bcdedit", "/delete", g) //nolint:errcheck
		}
		os.Remove(guidPath) //nolint:errcheck
	}
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
//
// Each entry is pulled out of the PERMANENT firmware displayorder before the
// delete, because the delete itself is not reliable: /copy can fail
// transiently ("registry key marked for deletion", #74) leaving a
// half-created entry that /delete then fails on the same way — and that
// zombie sat in the firmware BootOrder AHEAD of Windows, so the first boot
// after a verified deploy went straight into Linux instead of returning to
// Windows (aurora run 32633715971: Boot0004 "wootc" from a failed first
// /copy booted Phase 2 while Boot0003 "Windows Boot Manager" never ran).
// That is the exact surprise the done screen promises cannot happen. The
// displayorder removal is a separate, smaller NVRAM write that succeeds even
// when the object delete does not — an undeletable entry that is in no boot
// order is inert.
func deleteWootcBCDEntries() {
	out, _ := runCmd("bcdedit", "/enum", "firmware")
	re := regexp.MustCompile(`(?ms)identifier\s+(\{[^}]+\})[^{]*?description\s+wootc\s*$`)
	for _, m := range re.FindAllStringSubmatch(out, -1) {
		runCmd("bcdedit", "/set", "{fwbootmgr}", "displayorder", m[1], "/remove") //nolint:errcheck
		runCmd("bcdedit", "/delete", m[1])                                        //nolint:errcheck
	}
}


// ── ESP discovery ─────────────────────────────────────────────────────────────

func findESP() (string, error) {
	// Find the FAT32 EFI System Partition and make sure it has a drive letter.
	//
	// Add-PartitionAccessPath -AssignDriveLetter is NOT synchronous: the letter
	// is published by the mount manager, so an immediate Get-Partition re-read
	// usually still shows none. The old code did exactly that single re-read and
	// then failed with "ESP drive letter not found" — which made the whole
	// install intermittently fail depending on how fast the box happened to be
	// (GUI E2E run 30512204223 died here while an identical run minutes earlier
	// passed). Poll for the letter instead of assuming it appeared.
	//
	// Also report "no ESP at all" separately: an unassigned letter and a missing
	// partition need completely different fixes, and the old message conflated
	// them by dereferencing a possibly-nil $esp.
	script := `
$ErrorActionPreference = 'Stop'

# AccessPaths is the source of truth, NOT DriveLetter. On an ESP, Get-Partition
# reports DriveLetter as NUL even when a letter IS assigned — the assignment
# shows up only as an "X:\" entry in AccessPaths. Keying off DriveLetter made
# findESP conclude "no letter", ask for one, and get:
#     Add-PartitionAccessPath : Cannot assign multiple drive letters to a partition.
# i.e. the install failed precisely BECAUSE the ESP was already mounted.
function Get-EspLetter($p) {
    $p = Get-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber
    foreach ($ap in @($p.AccessPaths)) {
        if ($ap -match '^([A-Za-z]):\\$') { return $Matches[1] }
    }
    if ($p.DriveLetter -and $p.DriveLetter -ne [char]0) { return [string]$p.DriveLetter }
    return ''
}

# The ESP MUST be the one that backs Windows Boot Manager (#51). The BCD entry
# we create is a copy of {bootmgr} and inherits ITS device, so staging files on
# a different disk's ESP produces an install that looks complete and boots to a
# path that does not exist — while possibly overwriting another OS's ESP.
# Windows' own system disk is the unambiguous derivation: take C:'s disk.
$sysDisk = (Get-Partition -DriveLetter C -ErrorAction SilentlyContinue).DiskNumber
if ($null -eq $sysDisk) {
    Write-Output 'WOOTC_NO_SYSTEM_DISK'
    exit 0
}
$esp = Get-Partition -DiskNumber $sysDisk -ErrorAction SilentlyContinue |
       Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
       Select-Object -First 1
if (-not $esp) {
    # Same disk, FAT32, small: still constrained to the Windows disk. We do NOT
    # fall back to an arbitrary/first ESP anywhere on the machine — refusing is
    # safer than writing to someone else's boot partition.
    $esp = Get-Volume -ErrorAction SilentlyContinue |
           Where-Object { $_.FileSystemType -eq 'FAT32' -and $_.Size -lt 1GB } |
           Get-Partition -ErrorAction SilentlyContinue |
           Where-Object { $_.DiskNumber -eq $sysDisk } |
           Select-Object -First 1
}
if (-not $esp) {
    Write-Output 'WOOTC_NO_ESP'
    exit 0
}

$letter = Get-EspLetter $esp
if (-not $letter) {
    # Tolerate a losing race: if something assigned a letter between the check
    # and here, "already assigned" is success, not failure. Re-read either way.
    try { $esp | Add-PartitionAccessPath -AssignDriveLetter } catch { }
    # The mount manager publishes the letter asynchronously — poll, do not assume.
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        $letter = Get-EspLetter $esp
        if ($letter) { break }
    }
}
Write-Output $letter
`
	out, err := runPowerShellOutput(script)
	if err != nil {
		// runCmd returns CombinedOutput, so the PowerShell error text is right
		// here — dropping it left the GUI reporting only "ESP discovery: exit
		// status 1" (nightly run 30530497117), which names nothing. Include it,
		// as the resize path a few lines up already does.
		return "", fmt.Errorf("ESP discovery: %w (powershell said: %s)", err, strings.TrimSpace(out))
	}
	// A partition with no letter reports DriveLetter as NUL, not "" — trim it or
	// the length check below sees a 1-character "letter" that is really nothing.
	letter := strings.Trim(out, " \t\r\n\x00")
	if letter == "WOOTC_NO_SYSTEM_DISK" {
		return "", fmt.Errorf("could not determine which disk Windows starts from, so wootc cannot " +
			"safely choose an EFI system partition. Refusing to guess")
	}
	if letter == "WOOTC_NO_ESP" {
		return "", fmt.Errorf("no EFI System Partition was found on the disk Windows starts from. " +
			"wootc will not write to another disk's boot partition, because the boot entry it " +
			"creates always points at Windows' own disk")
	}
	if len(letter) != 1 {
		return "", fmt.Errorf("ESP found but Windows never assigned it a drive letter within 15s (output: %q)", out)
	}
	return letter + `:\`, nil
}
// ── Uninstall ─────────────────────────────────────────────────────────────────
