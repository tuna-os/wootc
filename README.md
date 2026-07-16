# wootc — Windows-hosted bootc Linux

wootc installs a bootc-based Linux system into `root.disk`, a sparse file on
an unencrypted Windows NTFS volume. It is a Wubi-style design: no repartitioning
of the Windows OS volume is required, and removal is deleting the installation
directory and its Windows boot entry.

This is early, boot-path-focused development. The project currently targets a
specific acceptance path:

```
Windows 11 → wootc deployer → native Linux from root.disk → Windows 11
```

Native loop-root boot is the implementation priority. The VM experience,
graphical installer, User Data Bridge, and Windows-removal migration are not
implemented yet.

## Current status (2026-07-16)

**Deployer execution is green.** The deployer boots under Secure Boot via the
Fedora shim → signed GRUB chain, mounts the NTFS volume, builds the ext4
scratch loop, and runs fisherman to completion. Verification succeeds and the
system reboots cleanly back to Windows.

**Phase-2 Linux boot is the active blocker.** The installed kernel and
initramfs live inside `root.disk` on NTFS. The signed GRUB cannot load
unsigned modules (ntfs.mod) under Secure Boot, so it can neither read
`root.disk` from the NTFS volume nor loop-mount the boot partition.

Two resolution paths exist (see [docs/e2e-architecture.md](docs/e2e-architecture.md)):

1. **ESP kernel-sync** (recommended): the deployer copies the installed
   kernel + initramfs to the EFI System Partition during verification.
   The GRUB entry loads them directly; the installed dracut module
   (`99wootc-boot`) handles NTFS mount and loop root attachment via kernel
   ntfs3 — no GRUB NTFS needed.
2. **MOK-enroll a custom signed GRUB** (wubildr with ntfs+loopback):
   preserves the root.disk-resident kernel design but adds a one-time
   MokManager enrollment step.

## Implemented path: Phase 2 native boot

1. The Windows installer creates `C:\wootc\disks\root.disk`, downloads the
   deployer kernel/initramfs and Fedora-signed shim + GRUB EFI binaries, and
   writes a one-shot Windows Boot Manager entry.
2. The Secure Boot chain is **`shimx64.efi → grubx64.efi → grub.cfg`** (all
   Microsoft/Fedora-signed). Deployer kernel+initramfs live on the ESP (256 MB)
   since the signed GRUB can only read FAT32.
3. The deployer mounts the Windows NTFS volume, attaches `root.disk` to a loop
   device, and uses fisherman to partition and populate it from a bootc image.
4. After deployment, it adds the `99wootc-boot` dracut module to the target,
   adds `wootc.host_uuid` and `loop=/wootc/disks/root.disk` to the target BLS
   entries, and regenerates initramfs. (Verification succeeds as of 2026-07-16.)
5. **BLOCKED:** On the Phase 2 boot, dracut mounts the NTFS host volume
   read-write, attaches `root.disk`, and mounts the target root — but the signed
   GRUB chain cannot load the kernel from inside `root.disk` on NTFS. See
   resolution paths above.

## Future phases (not implemented)

### Phase 1: VM boot and User Data Bridge

The intended first-use experience is to boot the same `root.disk` in QEMU
while Windows remains running. Windows data would be presented to Linux through
a User Data Bridge (virtio or network sharing) at the same canonical paths that
native boot will later use.

This repository does not currently provide the QEMU launcher, Windows
Hypervisor Platform integration, shared-folder bridge, user-directory mapping,
or the graphical UI/control panel for this phase.

### Phase 3: standalone Linux

After a user has migrated data from Windows storage to native Linux storage,
the intended final state is removal of Windows and the NTFS dependency. At that
point `root.disk` may be replaced by a native disk layout.

No data-migration assistant, storage conversion, Windows removal workflow, or
rollback UX has been implemented.

## Repository layout

- `app/` — Wails Windows installer.
- `payload/deployer/` — one-shot initramfs and deploy script.
- `payload/wubildr/` — reproducible custom GRUB EFI build.
- `platform/dracut/99wootc-boot/` — Phase 2 loop-root hook.
- `platform/grub/` — external GRUB configuration.
- `tests/e2e/` — KVM-backed Windows 11 test harness.

## E2E expectations

The E2E harness runs on Kanpur (a Bluefin/Fedora Silverblue KVM host) with
QEMU Guest Agent as the control plane. The VM requires KVM, UEFI Secure Boot,
and TPM 2.0.

### Build and run

```bash
# Build deployer initramfs + custom GRUB
just build

# Run on Kanpur (~30 min full, ~5 min quick with existing disk)
just kanpur-e2e          # fresh install + deploy
just kanpur-e2e-quick    # skip install (reuse disk)
```

### Kanpur operations

```bash
just kanpur-logs         # tail runner log
just kanpur-status       # grep for PASS/FAIL markers
just kanpur-serial       # watch serial console
just kanpur-check-files  # check root.disk via QGA
just kanpur-restore snap # restore from snapshot

# QGA interaction
just qga-ping            # ping guest agent
just qga-ps hostname     # run PowerShell
just qga-read C:/OEM/wootc-e2e.log  # read file from VM
just qga-oem-log         # read OEM log
just qga-reboot          # reboot Windows VM
```

### Debug loop (see docs/e2e-architecture.md for diagrams)

The deployer has **no interactive input** — the serial console is read-only.
Failures must reboot to Windows on their own. Debugging is:

1. Read the deployer journal via QGA: `C:\wootc\logs\deployer-last-journal.log`
2. Patch the initramfs on Kanpur (`bsdtar newc + zstd`)
3. Re-arm the BCD one-shot and reboot into deployer
4. Watch serial markers via `just kanpur-serial`

The full test is still under active development. The Phase-2 Linux boot leg is
the active blocker; do not yet treat this as a released installer.

## Constraints

- The Windows host volume must be unencrypted. BitLocker-protected volumes are
  not directly mountable by Linux's NTFS driver.
- Windows Fast Startup must be disabled; Linux needs a clean, writable NTFS
  volume. A dirty NTFS volume blocks the deployer immediately.
- **Secure Boot blocks unsigned GRUB modules.** The deployer uses the
  Fedora-signed shim + GRUB chain. Kernel and initramfs live on the FAT32 ESP.
- Initramfs root is **ramfs** (not tmpfs). Heavy I/O must target a disk-backed
  ext4 scratch loop on the NTFS volume or RAM is exhausted mid-deploy.
- Serial console is **read-only** during deployer phase. All diagnostics are
  pushed out via `/dev/kmsg` and persisted to `C:\wootc\logs\` before reboot.

See [docs/SPEC.md](docs/SPEC.md) for the broader design,
[docs/e2e-architecture.md](docs/e2e-architecture.md) for the boot-chain diagrams,
and [CONTEXT.md](CONTEXT.md) for the project vocabulary.
