# wootc — Windows bootc Installer

Install bootc-based Linux images from Windows — no USB drive, no
repartitioning, no risk. Downloads a bootc OCI image, deploys it to a
file on your Windows partition, and sets up dual-boot automatically.

> **Specification**: [docs/SPEC.md](docs/SPEC.md) — the canonical technical spec.

**wootc** is a spiritual successor to [Wubi](https://github.com/hakuna-m/wubiuefi)
(WubiUEFI), replacing Ubuntu's ISO + casper + ubiquity model with a
minimal bootc deployer. The result: smaller downloads (deltas, not full
ISOs), faster installs (no live environment), and direct-to-bootc-image
deployment.

## How It Works

```
┌──────────────────────────────────────────────────────────────┐
│ Windows                                                      │
│  1. wootc.exe downloads deployer kernel + initramfs (~150MB) │
│  2. Creates root.disk (empty virtual disk on NTFS)           │
│  3. Adds Windows Boot Manager → GRUB2 chainload entry        │
└──────────────────────────┬───────────────────────────────────┘
                           │ reboot
                           ▼
┌──────────────────────────────────────────────────────────────┐
│ GRUB2 (first boot)                                           │
│  4. Loop-mounts root.disk                                    │
│  5. Finds no OS → boots deployer initramfs                   │
│  6. Deployer: pulls bootc OCI image, bootc to-disk →         │
│     populates root.disk                                      │
│  7. Reboot                                                    │
└──────────────────────────┬───────────────────────────────────┘
                           │ reboot
                           ▼
┌──────────────────────────────────────────────────────────────┐
│ GRUB2 (subsequent boots)                                     │
│  8. Loop-mounts root.disk                                    │
│  9. Finds installed OS → boots it directly                   │
│ 10. Full bootc immutable Linux system, running from NTFS     │
└──────────────────────────────────────────────────────────────┘
```

## Why This Over a Normal Install

- **No USB drive needed** — install directly from Windows
- **No repartitioning** — the OS lives in a file on your existing NTFS partition
- **Uninstall is trivial** — delete the file from Windows, remove the boot entry
- **Small download** — the deployer is ~150MB, and OCI pulls are delta-only
- **Pre-configured** — bootc images are ready to boot, no "installer wizard" step
- **Immutable** — bootc gives you atomic updates and rollback

## Status

Early development. The deployer initramfs is being built. The Windows
installer is planned as an adaptation of wubiuefi's Win32 GUI.

## Architecture

See [docs/SPEC.md](docs/SPEC.md) for the full specification.

## License

GPL-2.0 (inherited from wubiuefi)
