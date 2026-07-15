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

## Implemented path: Phase 2 native boot

1. The Windows installer creates `C:\wootc\disks\root.disk`, downloads the
   deployer kernel/initramfs and custom `wubildr.efi`, and writes a one-shot
   Windows Boot Manager entry.
2. `wubildr.efi` is a GRUB core image with NTFS and loopback support. It finds
   `C:\wootc\install\wubildr.cfg`, then either starts the deployer or loads
   the installed disk image's GPT `/boot` partition.
3. The deployer mounts the Windows NTFS volume, attaches `root.disk` to a loop
   device, and uses fisherman to partition and populate it from a bootc image.
4. After deployment, it adds the `99wootc-boot` dracut module to the target,
   adds `wootc.host_uuid` and `loop=/wootc/disks/root.disk` to the target BLS
   entries, and regenerates initramfs.
5. On the Phase 2 boot, dracut mounts the NTFS host volume read-write, attaches
   `root.disk`, and mounts the target root. A subsequent reboot returns to
   Windows because the BCD handoff is one-shot.

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

The E2E VM requires KVM, UEFI Secure Boot, and TPM 2.0. The harness verifies
those QEMU features before waiting for Windows installation and captures a
console screenshot on VM startup failures.

Build the needed artifacts with:

```bash
just build-deployer
```

Then run the test on a KVM-capable Linux host:

```bash
just e2e
```

The full test is still under active development. In particular, its final
Windows → Phase 2 Linux → Windows orchestration is being completed alongside
the boot path; do not yet treat it as a released installer.

## Constraints

- The Windows host volume must be unencrypted. BitLocker-protected volumes are
  not directly mountable by Linux's NTFS driver.
- Windows Fast Startup must be disabled; Linux needs a clean, writable NTFS
  volume.
- `wubildr.efi` is unsigned, so physical Secure Boot support needs a signing
  path. The E2E VM uses a test firmware configuration.

See [docs/SPEC.md](docs/SPEC.md) for the broader design and
[CONTEXT.md](CONTEXT.md) for the project vocabulary.
