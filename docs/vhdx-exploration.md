# VHD/VHDX root disk exploration

Branch goal: evaluate replacing the raw `root.disk` with a Microsoft
virtual-disk format, so Windows Disk Management can mount the Linux root
volume natively for recovery, per SPEC §9.4.

## Format decision: fixed VHD first, dynamic VHDX later

| | raw (today) | **fixed VHD** | dynamic VHDX |
|---|---|---|---|
| Windows-mountable | no | **yes** | yes |
| Linux loop-mountable | yes | **yes** (footer-aware) | no — needs qemu-nbd/ublk |
| Sparse on NTFS | yes (fsutil sparse) | **yes** (same) | yes (internal) |
| Crash-resilience log | no | no | yes |
| Boot-path changes | — | **~3 small edits** | qemu-nbd + nbd.ko into target initramfs + deployer |

A fixed VHD is byte-for-byte a raw disk image with a single 512-byte
footer appended. Everything that boots today keeps working with two
adjustments:

1. **Loop attach must exclude the footer**: `losetup --sizelimit $((size - 512))`
   in `platform/dracut/99wootc-boot/wootc-attach-loop.sh` and in
   `payload/deployer/deploy.sh`. Otherwise the GPT backup header lands on
   the footer sector (bootc install would overwrite the footer, and the
   kernel would look for the backup GPT in the wrong place).
2. **Footer written after deployment**: deploy.sh appends the footer once
   `bootc install` finishes, so the GPT the installer writes is sized to
   the payload area, not the file. Creation-side (`setup-wootc.ps1` /
   `app/app.go`) sizes the file as N GiB + 512 bytes.

Sparseness is *not* a VHDX differentiator here: root.disk is already an
NTFS sparse file. The resilience log is the only capability fixed VHD
lacks; revisit dynamic VHDX (qemu-nbd in the initramfs) post-MVP if crash
data shows metadata corruption actually occurring.

## Why this does not unblock MVP by itself

The current Phase-2 blocker is a kernel panic that fires before any
console registers — before the initramfs ever touches root.disk. The disk
container format is orthogonal to that failure; this branch is a
recovery-UX improvement, not a fix for the panic.

## Implementation checklist

- [ ] `tests/e2e/setup-wootc.ps1` step 2: create `root.disk` as N GiB + 512 B
      sparse file (name stays `root.disk`; format detected by footer probe)
- [ ] `app/app.go` `createRootDisk`: same sizing change
- [ ] `payload/deployer/deploy.sh`: `losetup --sizelimit`, write VHD footer
      (cookie `conectix`, fixed type, CHS+size fields, checksum) post-install
- [ ] `platform/dracut/99wootc-boot/wootc-attach-loop.sh`: probe last 512 B
      for `conectix` cookie → attach with `--sizelimit`
- [ ] `tests/e2e/setup-wootc.ps1` wubildr.cfg: GRUB `loopback` fallback reads
      the raw offset region unchanged (footer is past everything it reads)
- [ ] E2E on himachal: full deploy + Phase-2 boot + Windows
      Disk Management attach test via QGA (`Mount-DiskImage`)
