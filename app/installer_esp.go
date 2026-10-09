//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
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
	defer releaseESPLetter()

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

// configureBCD prepares the boot chain as a journaled transaction (boot_txn.go):
// it proves the staged ESP chain, creates the firmware entry, records it for
// recovery, and proves the entry is INERT — in no boot order and not armed.
// The one-shot that makes it boot is set later by armBootChain, the last
// change before reboot, so an interruption anywhere in between returns to
// Windows. Any failure here rolls back what this step changed.
func configureBCD(cfg InstallConfig) error {
	var efiRelPath string

	switch cfg.Bootloader {
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

	// The entry may only boot files wootc staged and can attribute. Fail
	// closed: without the ownership manifest there is no chain to verify.
	espPath, err := findESP()
	if err != nil {
		return fmt.Errorf("locating the EFI boot partition to verify the staged boot files: %w", err)
	}
	defer releaseESPLetter()
	owned, err := readESPOwnership(espPath)
	if err != nil {
		return fmt.Errorf("reading the ESP ownership manifest: %w", err)
	}
	staged := make(map[string]string)
	var espFiles []string
	for f := range owned {
		h, err := hashFile(filepath.Join(espPath, filepath.FromSlash(f)))
		if err != nil {
			return fmt.Errorf("staged boot file %s is not readable: %w", f, err)
		}
		staged[f] = h
		espFiles = append(espFiles, f)
	}
	sort.Strings(espFiles)

	// ── Arm-time recovery guard state & task registration (§2) ────────────────
	// 1. Stage a copy of wootc.exe under install\ and compute its hash.
	installExe := filepath.Join(wootcDir(), "install", "wootc.exe")
	exeHash := ""
	curExe, errExe := os.Executable()
	if errExe == nil {
		if !strings.EqualFold(curExe, installExe) {
			if inData, errRead := os.ReadFile(curExe); errRead == nil {
				_ = os.WriteFile(installExe, inData, 0o755)
			}
		}
		if h, errHash := hashFile(installExe); errHash == nil {
			exeHash = h
		} else if h2, errHash2 := hashFile(curExe); errHash2 == nil {
			exeHash = h2
		}
	}

	// 2. Read prior power state.
	powerState := PriorPowerState{}
	if b, err := os.ReadFile(priorPowerPath()); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			parts := strings.SplitN(line, "=", 2)
			if len(parts) == 2 {
				switch strings.TrimSpace(parts[0]) {
				case "hibernate":
					powerState.HibernateEnabled = strings.TrimSpace(parts[1])
				case "hiberboot":
					powerState.HiberbootEnabled = strings.TrimSpace(parts[1])
				}
			}
		}
	}

	storageDrive := cfg.StorageDrive
	if storageDrive == "" {
		storageDrive = "C"
	}

	armed := ArmedState{
		EspPartitionGuid: findESPPartitionGuid(),
		EspFiles:         espFiles,
		EspFileHashes:    staged,
		PriorPowerState:  powerState,
		StorageDrive:     storageDrive,
		ImageRef:         cfg.ImageRef,
		Bootloader:       cfg.Bootloader,
		Timestamp:        time.Now().UTC().Format(time.RFC3339),
		ExeHash:          exeHash,
	}

	// 3. Register the recovery tasks BEFORE the first BCD write, so a power
	// cut from here on is rolled back by `recover --startup` on the next
	// Windows start (bootTxnStartupAction).
	if err := registerRecoveryTasks(installExe); err != nil {
		fmt.Printf("warning: could not register recovery tasks: %v\n", err)
	}

	_, err = beginBootChainTxn(windowsBootChainEnv(espPath, armed), efiRelPath, staged)
	return err
}

// armBootChain sets the one-shot bootsequence of the prepared chain — the
// transaction's commit point — and proves the armed chain by observation. On
// failure the boot changes are rolled back and Windows starts normally.
func armBootChain() error {
	txn, err := readBootTxn()
	if err != nil {
		return fmt.Errorf("no prepared boot chain to arm (boot-txn.json): %w", err)
	}
	armed, err := readArmedJSON()
	if err != nil {
		return fmt.Errorf("no recovery record for the boot chain (armed.json): %w", err)
	}
	espPath, err := findESP()
	if err != nil {
		return fmt.Errorf("locating the EFI boot partition to verify the staged boot files: %w", err)
	}
	defer releaseESPLetter()
	_, err = armBootChainTxn(windowsBootChainEnv(espPath, armed), txn)
	return err
}

// windowsBootChainEnv wires the transaction to bcdedit and the real ESP.
// onEntry writes bcd-guid.txt and armed.json for each entry it creates: the
// E2E harness re-arms the Phase-2 boot from bcd-guid.txt, and recovery and
// uninstall find the entry through both.
func windowsBootChainEnv(espPath string, armed ArmedState) bootChainEnv {
	return bootChainEnv{
		bcdedit: func(args ...string) (string, error) { return runCmd("bcdedit", args...) },
		hashESP: func(rels []string) map[string]string {
			out := make(map[string]string, len(rels))
			for _, rel := range rels {
				if h, err := hashFile(filepath.Join(espPath, filepath.FromSlash(rel))); err == nil {
					out[rel] = h
				}
			}
			return out
		},
		saveTxn: writeBootTxn,
		onEntry: func(guid string) error {
			if err := writeFileSynced(filepath.Join(wootcDir(), "install", "bcd-guid.txt"), guid); err != nil {
				return err
			}
			armed.BcdGuid = guid
			return writeArmedJSON(armed)
		},
		sleep: time.Sleep,
	}
}

// findESPPartitionGuid returns the GPT partition GUID of the Windows system disk's ESP.
func findESPPartitionGuid() string {
	script := `
$sysDisk = (Get-Partition -DriveLetter C -ErrorAction SilentlyContinue).DiskNumber
if ($null -ne $sysDisk) {
    $esp = Get-Partition -DiskNumber $sysDisk -ErrorAction SilentlyContinue |
           Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
           Select-Object -First 1
    if ($esp -and $esp.Guid) {
        Write-Output $esp.Guid
    }
}
`
	out, err := runPowerShellOutput(script)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// disarmOneShot undoes the boot arming after a cancelled or failed install.
// Without it, a user who cancelled at 82% — or whose install failed at
// "Saving your settings" — still had a live one-shot pointing at a
// half-configured deployer, and got a surprise Linux boot attempt on their
// next restart while the UI told them "nothing permanent changes".
//
// It rolls the boot-chain transaction back and then LOOKS (boot_txn.go). When
// the rollback cannot be confirmed it fails closed: the journal, armed.json
// and the recovery tasks stay, so the next Windows start retries the cleanup
// instead of believing it happened.
func disarmOneShot() {
	removeBootmgrSelfReference()
	releaseESPLetter()
	if err := rollbackBootChain(); err != nil {
		fmt.Fprintf(os.Stderr, "[wootc] %v — the recovery task retries on the next Windows start\n", err)
		return
	}
	os.Remove(filepath.Join(wootcDir(), "install", "bcd-guid.txt")) //nolint:errcheck
	_ = unregisterRecoveryTasks()
	_ = os.Remove(armedPath())
}

// rollbackBootChain rolls back the journaled transaction. An unreadable
// journal (a power cut mid-write) still rolls back: by entry description and
// the GUID in bcd-guid.txt.
func rollbackBootChain() error {
	txn, err := readBootTxn()
	if err != nil {
		txn = BootTxn{}
		if b, rerr := os.ReadFile(filepath.Join(wootcDir(), "install", "bcd-guid.txt")); rerr == nil {
			if g := strings.TrimSpace(string(b)); validBCDGUID(g) {
				txn.BcdGuid = g
			}
		}
	}
	env := bootChainEnv{
		bcdedit: func(args ...string) (string, error) { return runCmd("bcdedit", args...) },
		saveTxn: writeBootTxn,
		sleep:   time.Sleep,
	}
	_, err = rollbackBootChainTxn(env, txn)
	return err
}

// deleteWootcBCDEntries removes every firmware entry named exactly "wootc"
// plus the GUID in bcd-guid.txt, and only wootc's element of the one-shot.
//
// Each entry is pulled out of the PERMANENT firmware displayorder before the
// delete, because the delete itself is not reliable: /copy can fail
// transiently ("registry key marked for deletion", #74) leaving a
// half-created entry that /delete then fails on the same way — and that
// zombie sat in the firmware BootOrder AHEAD of Windows, so the first boot
// after a verified deploy went straight into Linux instead of returning to
// Windows (aurora run 32633715971). The displayorder removal is a separate,
// smaller NVRAM write that succeeds even when the object delete does not — an
// undeletable entry that is in no boot order is inert.
func deleteWootcBCDEntries() {
	guid := ""
	if b, err := os.ReadFile(filepath.Join(wootcDir(), "install", "bcd-guid.txt")); err == nil {
		if g := strings.TrimSpace(string(b)); validBCDGUID(g) {
			guid = g
		}
	}
	sweepWootcEntries(bootChainEnv{
		bcdedit: func(args ...string) (string, error) { return runCmd("bcdedit", args...) },
	}, guid)
	removeBootmgrSelfReference()
}

// removeBootmgrSelfReference takes Windows Boot Manager out of its own boot
// menu, where older builds put it on every install (#551). Best-effort, and a
// no-op on a machine that never had it.
func removeBootmgrSelfReference() {
	out, err := runCmd("bcdedit", "/enum", "{bootmgr}")
	if err != nil || !bootmgrListsItself(out) {
		return
	}
	runCmd("bcdedit", "/displayorder", "{bootmgr}", "/remove") //nolint:errcheck
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
    # Tell the caller this run assigned the letter, so it is removed again
    # when wootc is done with the ESP (#551).
    if ($letter) { $letter = "ASSIGNED:$letter" }
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
	letter, assignedByUs := parseESPDiscovery(out)
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
	if assignedByUs {
		// Recorded on disk, not only in memory, so recovery and uninstall
		// can remove the letter after a crash or an abort.
		marker := espLetterMarker()
		_ = os.MkdirAll(filepath.Dir(marker), 0o755)
		_ = os.WriteFile(marker, []byte(letter+"\n"), 0o644)
	}
	return letter + `:\`, nil
}

func espLetterMarker() string {
	return filepath.Join(wootcDir(), "install", "esp-letter-assigned.txt")
}

// releaseESPLetter removes the ESP drive letter that findESP assigned, so
// the EFI partition does not stay visible in Explorer after wootc is done
// with it (#551). A letter the user or Windows assigned is never touched:
// only one recorded in the marker is removed, and only while it still points
// at an EFI partition. Best-effort.
func releaseESPLetter() {
	marker := espLetterMarker()
	b, err := os.ReadFile(marker)
	if err != nil {
		return
	}
	letter := strings.TrimSpace(string(b))
	if len(letter) == 1 {
		if _, err := os.Stat(letter + `:\EFI`); err == nil {
			runCmd("mountvol", letter+":", "/D") //nolint:errcheck
		}
	}
	_ = os.Remove(marker)
}

// ── Uninstall ─────────────────────────────────────────────────────────────────
