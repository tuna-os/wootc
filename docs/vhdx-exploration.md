# Dynamic VHDX root disk exploration

## Decision

`root.vhdx` replaces the raw `root.disk` container. We do not use
fixed VHD. VHDX provides the recovery UX we want (native Windows
attach) plus an allocation log for metadata crash resilience.

Windows creates a **dynamic VHDX** with DiskPart. The `.vhdx` extension makes
the format explicit, and VHDX allocates sparsely on NTFS without a custom
footer or raw-file heuristic.

## Linux attachment model

VHDX is not a raw block file. Both Linux paths attach it format-aware through
QEMU NBD:

```
Windows NTFS → C:\wootc\disks\root.vhdx
                    │
             qemu-nbd --format=vhdx
                    │
                /dev/nbd0p* → fisherman / Phase-2 root
```

The deployer includes `qemu-nbd` and `nbd.ko`. During deployment it copies the
binary into the target's `99wootc-boot` dracut module; that module inserts the
NBD driver and adds the binary to the Phase-2 initramfs. The EFI path does
not change: the kernel and initramfs remain on the ESP. The initramfs makes the
root UUID on the VHDX appear before `sysroot.mount` runs.

## Required validation

- Windows OEM: `Mount-DiskImage` attaches `root.vhdx`, then dismounts it.
- Deployer: `qemu-nbd --format=vhdx` exposes the expected partitions and
  fisherman completes.
- Phase 2: the target initramfs contains `qemu-nbd` and `nbd.ko`, then boots
  the VHDX root through `/dev/nbd0`.
- Phase 1 launcher work must use QEMU `format=vhdx`, not `format=raw`.
- Reboot from Phase 2 returns to Windows as before.

## Open risk

The target initramfs must include each QEMU block driver that `qemu-nbd`
needs. The first E2E run must inspect `lsinitrd`. It must also prove that
`qemu-nbd` can open a VHDX after dracut makes the target initramfs again.
