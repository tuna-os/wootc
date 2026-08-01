# Finishing plan — dakota (composefs), btrfs, and the rest of the matrix

*Written 2026-08-01. Scope set by the maintainer: get `dakota`, composefs,
and btrfs green. Windows 10 Home/Enterprise/LTSC (#58) is explicitly
deprioritized ("pretty rare").*

The project's green core is done: `bluefin:lts` (ostree/grub2/ext4-sealed)
passes the full Phase 1 → 2 → 3 chain, GUI-driven, 29/29. What separates
"working demo for one image family" from "finished installer" is the red
half of the build/test matrix, and almost all of it funnels through two
bugs: the composefs Phase-2 staging path (#28) and btrfs device readiness
(#35).

## Where each red cell actually is

| Red cell | Funnel | Blocking defect |
|---|---|---|
| `dakota` deploy → Phase 2 | #28 | early-cpio staging: incoherent ntfs-3g sourcing, unverified initrd |
| `marlin` / `flounder` deploy | #28 | same composefs-native path (backend detection fixed in 96d1f5b) |
| btrfs sealed root | #35 | root device never becomes SYSTEMD_READY; sysroot.mount times out |
| `tpm2-luks` | #33 | Phase-2 dracut regen fails on the LUKS root (independent track) |
| Matrix ✅s predating 2026-07-27 | harness | being re-run under the failure-ledger harness (already fixed in 3d7f9e2) |

## What this branch fixes (code-side, container-verifiable)

1. **One early-cpio implementation** (`stage_wootc_overlay`,
   `stage_ntfs3g_closure`, `build_phase2_initrd` in `deploy.sh`), used by
   all three prepend-cpio branches. The `/mnt/sysroot` phantom paths are
   gone. ntfs-3g is sourced coherently: the target deployment's own binary
   + libraries first; otherwise the deployer's binary as a **complete
   private closure** (every `NEEDED` lib + the loader under
   `/usr/lib/wootc/ntfs3g/`, wrapper-invoked, exec-verified at stage time)
   — agent-lessons §8, mechanically enforced.
2. **The built Phase-2 initrd is verified by inspection**: overlay
   completeness (unit, wants edge, executable hook) before packing; the
   base initrd is listed and must ship the hook's interpreter and tools
   (`bash losetup udevadm mount`) — fail closed on proof, warn on
   unlistable. Mutation-tested in `tests/unit/phase2-early-cpio.bats`.
3. **#45 fail-closed**: a deploy whose installed root cannot be mounted and
   recognized exits 1 with the partition table, per-partition blkid, and
   bounded mount errors — it no longer advertises deploy-ready and reboots.
4. **#35 layered fix**: btrfs deploys bake a `modules-load.d` entry into
   the regenerated Phase-2 initramfs (early, dependency-resolved btrfs.ko
   load — no hook modprobe, honoring the Secure Boot lockdown lesson); the
   attach hook registers the just-attached partitions (`btrfs device
   scan`), re-triggers CHANGE events so udev's readiness import re-runs,
   and logs `module loaded= SYSTEMD_READY=` per btrfs partition so a
   persisting failure is diagnosable from one serial log.

## What only the E2E rig can do (the actual finish line)

Each rung is one KVM run; do them in this order, one change per run:

1. **btrfs re-run** (`wootc.filesystem=btrfs`, bluefin:lts): expect green;
   if not, the new `btrfs <part>: module loaded=… SYSTEMD_READY=…` serial
   line says which layer failed. When green twice, consider flipping the
   sealed default to btrfs (native fs-verity, reflinks) — a product call,
   not a bug fix; ext4 stays default until then.
2. **dakota full chain**: deploy now runs the hardened staging; the
   composefs Phase-2 boot (deployer kernel + patched UKI initrd +
   root=UUID/composefs= kargs) is the first thing that has never been
   proven end-to-end. Expect the next failure — if any — *after* attach,
   in `bootc-root-setup`/composefs pivot; the verify guards will name it.
3. **marlin / flounder**: same path as dakota post-96d1f5b; run after
   dakota is green so composefs failures aren't double-counted.
4. **Matrix re-sweep** under the ledger harness to re-earn the pre-3d7f9e2
   ✅s (already tracked in README).
5. **#33 tpm2-luks**: independent; the regen now surfaces dracut's own
   output, so the next failing run carries its cause.

## Definition of done for "support for dakota, composefs, btrfs"

- dakota: Arm → Deploy → Phase-2 boot → seeded-file assertion green under
  the ledger harness (Phase-3 graduation is a follow-on rung).
- One non-dakota composefs-native family (marlin or flounder) green
  through Phase-2, proving the path is image-agnostic, not dakota-shaped.
- btrfs: bluefin:lts sealed-btrfs green through Phase-2 twice; #35 closed.
- All three keep their bats regression guards
  (`phase2-early-cpio.bats`, `btrfs-phase2.bats`) green in CI.
