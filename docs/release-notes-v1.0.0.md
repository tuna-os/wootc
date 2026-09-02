# wootc v1.0.0 — The North Star, checkable

**Release Date:** September 2026  
**Tag:** `v1.0.0`  
**Distribution:** Five branded installers + shared deployer boot artifacts + `SHA256SUMS`

---

## The Cut

wootc v1.0.0 marks the completion of the project's foundational milestone: making it as easy as possible for **non-technical Windows users** to migrate to Linux **without losing any of their data**. 

wootc installs a real, image-based bootc Linux system into a single `root.disk` file on the existing Windows NTFS volume — requiring no repartitioning, no upfront backups, and no point of no return.

1.0 is not an arbitrary feature count. It is the North Star made checkable against four rigorous criteria, evidenced across physical hardware, virtualized matrices, and continuous soak testing.

---

## What 1.0 Means: The Four Criteria & Evidence

### Criterion 1: The download-to-desktop journey needs no instructions beyond the app

A non-technical user installs (via `winget` or a single executable), reboots once, lands in Linux, finds their Windows files, and can return to Windows — guided entirely by what appears on screen.

- **Evidence & Verification:**
  - **Fresh-Eyes Usability Protocol ([#236](https://github.com/tuna-os/wootc/issues/236), `docs/manual-testing.md` § Fresh-eyes usability run):** Evaluated with non-technical participants given only a download URL and a single prompt ("This installs Linux next to your Windows; try it."). Participants completed the four journey stages unaided with zero blocking issues.
  - **Single Calm Reboot:** Windows BCD one-shot configuration seamlessly hands off to the signed shim/GRUB chain, runs the unattended deployer, and lands at the graphical Linux login screen.
  - **User Data Bridge:** The Windows user profile (`C:\Users\<User>`) is automatically detected, matched, and mounted into `$HOME/Windows` with desktop bookmarks and browser bookmark discovery.
  - **Reversible Return:** Windows remains the primary boot option in UEFI/BCD firmware; users can reboot straight back to Windows at any time from the boot menu or application shortcuts.

---

### Criterion 2: Zero known data-loss classes

Every destructive path is double-gated, reversible, and exercised by the test matrix. Uninstall provably restores the host machine to its exact pre-install state.

- **Evidence & Verification:**
  - **Destructive-Path Inventory & Verification ([#234](https://github.com/tuna-os/wootc/issues/234), [#237](https://github.com/tuna-os/wootc/issues/237)):** Every write operation outside `C:\wootc` is cataloged, gated by preflight checks, and covered by automated rollback tests (`tests/unit/test-verify-uninstall.ps1`, `tests/field/verify-uninstall.ps1`).
  - **Physical Hardware Uninstall Restoration ([#238](https://github.com/tuna-os/wootc/issues/238)):** The uninstaller cleans firmware boot entries (`bcdedit /enum firmware`), restores ESP files bit-for-bit against the pre-install ownership manifest (`esp_ownership.go`), and restores pre-install hibernation/Fast Startup states. Even if `C:\wootc` is manually deleted by the user prior to uninstallation, the settings survive via the Add/Remove registry mirror.
  - **Zero Open Data-Loss Reports:** Zero data-loss or boot-corruption reports across all recorded test runs and field report templates (`.github/ISSUE_TEMPLATE/manual-test-report.yml`).

---

### Criterion 3: Evidence, not claims

The release is backed by full matrix green status, a 30-day soak of green nightlies on `main`, and a corpus of real-hardware test reports.

- **Evidence & Verification:**
  - **30-Day Nightly Soak ([#235](https://github.com/tuna-os/wootc/issues/235), [#239](https://github.com/tuna-os/wootc/issues/239), `docs/soak.md`):** Thirty consecutive days of automated, GUI-driven end-to-end runs passing on `main` without unexplained failures or data-safety regressions.
  - **Full-Tier Matrix Green at Release SHA ([#240](https://github.com/tuna-os/wootc/issues/240)):** Verified across green catalog images, Windows 10 and 11 editions (Pro, Home, Enterprise, LTSC), root filesystems (`ext4`, `xfs`, `btrfs`), BitLocker FDE supported installations ([#34](https://github.com/tuna-os/wootc/issues/34), [#223](https://github.com/tuna-os/wootc/issues/223)), and offline (`-nic none`) bundle ingest ([#217](https://github.com/tuna-os/wootc/issues/217)).
  - **Real-Hardware Report Corpus ([#210](https://github.com/tuna-os/wootc/issues/210), [#216](https://github.com/tuna-os/wootc/issues/216)):** Multi-vendor physical machine runs (HP, Dell, Lenovo UEFI firmware) successfully validating the install → deploy → Linux → Windows return → uninstall cycle.

---

### Criterion 4: A trustworthy first impression

Signed binaries, clean UAC elevation without SmartScreen interstitials, stable package manager availability, and branded distribution approved by upstream projects.

- **Evidence & Verification:**
  - **Authenticode Code Signing ([#229](https://github.com/tuna-os/wootc/issues/229), [#230](https://github.com/tuna-os/wootc/issues/230), [#241](https://github.com/tuna-os/wootc/issues/241)):** Release executables carry valid Authenticode signatures and brand-specific `VERSIONINFO` resources, eliminating SmartScreen warnings and unknown-publisher prompts.
  - **winget Package Distribution ([#221](https://github.com/tuna-os/wootc/issues/221), `packaging/winget/`):** The `TunaOS.wootc` package is submitted and served via `microsoft/winget-pkgs`, enabling simple one-line installation (`winget install TunaOS.wootc`).
  - **Upstream Project Blessings ([#227](https://github.com/tuna-os/wootc/issues/227), `docs/upstream-blessings.md`):** Brand distribution policies and mark usage governance are formally documented and verified (`packaging/brands.sh`).

---

## What Is Deliberately Not in 1.0 (Honest Scope Decisions)

To preserve release stability and avoid untested promises, several capabilities have been deliberately scoped for post-1.0:

1. **Try-in-VM Pre-Install Preview ([#178](https://github.com/tuna-os/wootc/issues/178), [#231](https://github.com/tuna-os/wootc/issues/231)):**
   - *Decision:* Under ADR 0001 (Phase 1-first architecture), wootc populates `root.disk` directly on NTFS without modifying partitions. The user can immediately test drive their installed system via Phase 1 "Boot in VM" in Windows. Bundling ~100MB+ of non-vendored Windows QEMU binaries and Alpine builder kernels into the standard installer was cut to keep the download lightweight; pre-install VM preview is deferred to offline bundle media.
2. **Third-Party Program Migrator Plugin Loading ([#203](https://github.com/tuna-os/wootc/issues/203), [#232](https://github.com/tuna-os/wootc/issues/232)):**
   - *Decision:* wootc v1.0 refactors built-in migration bridges (browsers, Steam, WSL, Office) to conform to the standard `plugin.json` and lifecycle script contract (`docs/plugin-architecture.md`). Loading arbitrary third-party drop-in plugins from `/etc/wootc/plugins.d/` with cryptographic signature verification is scheduled for post-1.0.
3. **Session Credential Auto-Rewrapping for External Services ([#1](https://github.com/tuna-os/wootc/issues/1), [#228](https://github.com/tuna-os/wootc/issues/228)):**
   - *Decision:* While local DPAPI decryption succeeds on Windows, non-Chromium and proprietary service tokens are staged to the target user directory and visibly labeled "staged — re-link on Linux" rather than attempting fragile, undocumented token rewrites.

---

## Upgrade & Uninstall Promises

### Upgrade Promise
- The installed Linux environment is a standard, image-based **bootc** deployment.
- Operating system updates, security patches, and kernel upgrades are applied natively inside Linux via `bootc upgrade` or desktop software centers, without needing to re-run the Windows installer.
- The underlying `root.disk` container remains fully compatible across upgrades.

### Uninstall Promise
- Uninstalling wootc is safe, complete, and verifiable.
- Running `wootc.exe uninstall` or using Windows **Settings → Installed Apps → Uninstall**:
  1. Restores the Windows BCD firmware boot order and removes the wootc UEFI boot entry.
  2. Cleans up only wootc-owned files from the EFI System Partition (ESP), preserving all Windows and OEM boot files.
  3. Restores Windows power settings (hibernation and Fast Startup) to their exact pre-install state.
  4. Removes the `C:\wootc` directory, offering the user the explicit choice to retain or delete `root.disk`.
  5. Leaves Windows and all user documents completely intact.

---

## Installer Lineup & Upstream Alignment (M3.6)

wootc v1.0.0 is distributed as five tailored executables built from a unified core:

| Installer | Product Name | Target Distribution | Branding & Mark Status |
|---|---|---|---|
| `wootc.exe` | wootc (Generic) | Multi-distribution catalog | Self-owned (`tuna-os`) |
| `TunaOS-Installer.exe` | TunaOS Installer | TunaOS (`tunaos:latest`) | Self-owned (`tuna-os`) |
| `Bluefin-Installer.exe` | Bluefin Installer | Bluefin (`bluefin:lts`, `bluefin:latest`) | Universal Blue / Project Bluefin |
| `Aurora-Installer.exe` | Aurora Installer | Aurora (`aurora:latest`) | Universal Blue / Aurora |
| `Bazzite-Installer.exe` | Bazzite Installer | Bazzite (`bazzite:latest`) | Universal Blue / Bazzite |

Each branded executable incorporates deep visual styling, distinct typography, distribution icons, and curated catalog defaults per `docs/branding-and-distribution.md`.

---

## Artifacts & Verification

Every release asset is checksummed in `SHA256SUMS`. Users and automated tools can verify asset integrity:

```powershell
# Verify SHA-256 checksum on Windows
Get-FileHash wootc.exe -Algorithm SHA256

# Verify Authenticode Signature
Get-AuthenticodeSignature wootc.exe
```

### Published Assets:
- `wootc.exe` (Generic installer)
- `TunaOS-Installer.exe`
- `Bluefin-Installer.exe`
- `Aurora-Installer.exe`
- `Bazzite-Installer.exe`
- `deployer-vmlinuz` & `deployer-initramfs.img` (Deployer boot assets)
- `shimx64.efi`, `grubx64.efi`, `mmx64.efi` (Signed UEFI boot chain)
- `SHA256SUMS`
