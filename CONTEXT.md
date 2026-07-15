# wootc — Domain Glossary

## Phases of Adoption

**Phase 1 — VM Boot**: Linux runs inside QEMU on Windows, sharing the same desktop session. The same `root.disk` that will later boot bare-metal is used as the VM's disk. User data reaches Linux through a **User Data Bridge** — a virtio or network mechanism, since Windows has the NTFS partition locked.

**Phase 2 — Native Boot**: Linux boots bare-metal via GRUB → ntfs3 → losetup on the same `root.disk`. User data reaches Linux through **NTFS Passthrough** — direct bind-mounts of Windows user folders into `$HOME`, because Linux now has direct NTFS access.

**Phase 3 — Standalone Linux**: Windows is removed. All user data has been migrated to native Linux storage. The NTFS dependency is eliminated entirely — root.disk may become a native partition.

## Core Concepts

**root.disk**: A sparse file on the Windows NTFS partition that contains the entire Linux OS (GPT partition table, ESP, root filesystem). Created once during installation, reused across all three phases. Same bytes whether booted in QEMU or on bare metal.

**User Data Bridge**: The mechanism by which a user's Windows files (Documents, Pictures, Downloads, browser profiles, Steam libraries) become visible inside Linux. The implementation differs by phase — virtio/shared-folder in Phase 1, NTFS bind-mount in Phase 2 — but produces **identical canonical mount paths** in `$HOME`. This means the user can switch between Phase 1 and Phase 2 without any visible change to their file layout.

**wubildr**: A custom GRUB2 EFI core image with embedded bootstrap config and the `ntfs` + `loopback` modules. It chainloads from Windows Boot Manager and searches for `wubildr.cfg` on the Windows NTFS partition, enabling bare-metal boot without modifying the Windows partition table.

**shim**: A small EFI bootloader **signed by Microsoft** that is accepted by UEFI Secure Boot. Shim loads `grubx64.efi` (signed by a distribution's key, embedded in shim's MOK database) from the same directory. The boot chain is:

UEFI firmware → Windows Boot Manager → bootsequence → shimx64.efi (MS-signed) → grubx64.efi (distro-signed) → grub.cfg (on ESP) → deployer or Phase 2 Linux

This replaces the unsigned `wubildr.efi` which Secure Boot rejects with `Access Denied`.

**grub modules**: Fedora's signed `grubx64.efi` is a minimal image that loads additional modules (`ntfs.mod`, `loopback.mod`) from the ESP at runtime via `insmod`. These `.mod` files live on the FAT32 ESP alongside `grub.cfg`. Without them, GRUB cannot read the Windows NTFS partition and cannot find `root.disk`.

**BCD Entry**: A Windows Boot Manager entry (created via `bcdedit /copy {bootmgr}`) that points UEFI at `\EFI\wootc\wubildr.efi` on the ESP. Uses `bootsequence` for one-shot boots (test the deployer, test Phase 2) or `displayorder` for persistent dual-boot setups.

**vault.json**: A transient JSON file written to `C:\wootc\install\` during installation, containing the hashed user password ($6$ SHA-512), username, and hostname. The deployer initramfs reads it, injects credentials into the fisherman recipe, and shreds the file before a single OCI layer is extracted.

**Deployer**: A minimal Linux initramfs that runs once to populate `root.disk` with the chosen bootc image. It mounts the Windows NTFS partition, finds root.disk, sets up a loop device, runs fisherman, verifies the installation, and reboots.

**fisherman**: A Go binary (submodule at `fisherman/`) that partitions, formats, and runs `bootc install to-filesystem` into a target disk. Invoked by the Deployer with a JSON recipe. Handles Flatpak injection, LUKS encryption, and post-install hooks.

**Control Panel**: The wootc.exe screen shown when an existing `root.disk` is detected. Offers "Boot in VM" (Phase 1), "Reboot to Linux" (Phase 2), and "Uninstall" — all operating on the same underlying disk image.

## Boot Modes

**VM Boot** (Phase 1): QEMU boots `root.disk` as a raw block device (`-drive file=root.disk,if=virtio`). No NTFS dependency — QEMU provides its own block layer. Works while Windows is running. This is the recommended first experience after installation.

**Native Boot** (Phase 2): UEFI Secure Boot → Windows Boot Manager → bootsequence →
shimx64.efi (MS-signed) → grubx64.efi (Fedora-signed) → grub.cfg →
ntfs3 mount of Windows partition → losetup root.disk → boot installed OS.
Requires Windows to be shut down cleanly (ntfs3 refuses read-write mount on
dirty/hibernated volumes). Also requires the ESP to contain `ntfs.mod` and
`loopback.mod` alongside `grub.cfg` for GRUB to read NTFS, since Fedora's
signed grub does not embed these modules.

**Install Path**: The wootc.exe installer creates root.disk and runs the Deployer to populate it with the chosen bootc image. On completion, the user is offered "Boot in VM now" (Phase 1) or "Reboot to Linux" (Phase 2). There is no separate "Try in VM" preview — the VM IS the primary experience.
