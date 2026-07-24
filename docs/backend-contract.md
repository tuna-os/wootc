# Deployment-backend contract — measured, not assumed

Backend confusion has burned real cycles twice (the old detector keyed the
backend off the sealed flag; fisherman #55 mis-detected composefs layouts).
This file is the antidote: the **measured** classification of every supported
image family, the probe that produced it, and the vocabulary that keeps the
axes apart. If an image misbehaves, re-run the probe before theorizing.

## The two axes (never conflate them)

| Axis | Meaning | Detected from | Decides |
|---|---|---|---|
| **BACKEND** | how bootc deploys & boots the image | boot artifacts: signed bootupd GRUB present → `ostree`; systemd-boot-only and no `bootupctl` → `composefs-native` | bootloader (grub2 vs systemd-boot), `--composefs-backend`, fisherman layout (`/ostree/deploy` vs `/state/deploy`) |
| **SEALED** | rootfs is composefs/fs-verity sealed | `prepare-root.conf [composefs] enabled` | root filesystem only (btrfs for fs-verity — native since 5.15; deployer default xfs has none; ext4 -O verity by explicit request) |

**SEALED says nothing about the backend.** Every image below is sealed —
including plain-ostree yellowfin. "The image mentions composefs" is not
evidence of a composefs backend.

## Measured classification (probe run 2026-07-23, himachal)

| Image | BACKEND | SEALED | Bootloader | Phase-2 path |
|---|---|---|---|---|
| `ghcr.io/ublue-os/bluefin:stable` | **ostree** | 1 | grub2 | NTFS→loop→GRUB (proven) |
| `ghcr.io/ublue-os/bluefin:lts` | **ostree** | 1 | grub2 | NTFS→loop→GRUB |
| `ghcr.io/projectbluefin/bluefin:lts` | **ostree** | 1 | grub2 | NTFS→loop→GRUB (proven) |
| `ghcr.io/projectbluefin/dakota:latest` | **composefs-native** | 1 | systemd-boot | systemd-boot path |
| `ghcr.io/tuna-os/yellowfin:gnome` | **ostree** | 1 | grub2 | NTFS→loop→GRUB (proven) |

This matches the maintainers' ground truth (2026-07-23): bluefin stable/lts
are ostree backend; dakota is definitely composefs backend.

## Reproduce the measurement

```bash
podman run --rm --network=host "$IMG" sh -c '
  if { ls /usr/lib/bootupd/updates/EFI/*/grubx64.efi >/dev/null 2>&1 ||
       { test -f /usr/lib/bootupd/updates/EFI.json &&
         find /usr/lib/efi/grub2 -type f -name grubx64.efi -print -quit 2>/dev/null | grep -q . &&
         find /usr/lib/efi/shim  -type f -name shimx64.efi  -print -quit 2>/dev/null | grep -q .; }; }
  then echo BACKEND=ostree
  elif test -f /usr/lib/systemd/boot/efi/systemd-bootx64.efi && ! command -v bootupctl >/dev/null 2>&1
  then echo BACKEND=composefs-native
  else echo BACKEND=unknown
  fi
  grep -A8 "^\[composefs\]" /usr/lib/ostree/prepare-root.conf 2>/dev/null \
    | grep -qiE "enabled[[:space:]]*=[[:space:]]*(yes|true|1|signed)" && echo SEALED=1 || echo SEALED=0'
```

This is byte-for-byte the probe `payload/deployer/deploy.sh` runs at deploy
time (search for `BACKEND=ostree`). A hung/failed probe falls back to
ostree/grub2 + ext4 with a loud WARN — it never aborts a deploy.

## Where each detector lives

- **deploy.sh** — the probe above; sets `BOOTLOADER`, `COMPOSEFS`,
  `ROOTFS_SEALED` (→ ext4). Guarded in `tests/unit/backend-detection.bats`.
- **fisherman** (`internal/post/post.go isComposeFsNative`) — layout-time:
  `state/deploy` exists ⟺ composefs-native (plus legacy "no /ostree"
  fallback). This is the detector that mis-fired historically (#55).

## Vocabulary

Say **"ostree backend (sealed rootfs)"** for bluefin/yellowfin/bonito, and
**"composefs-native backend"** for dakota. Retire the phrase
"composefs-SEALED ostree" — it reads as a third backend and caused exactly
the confusion this file exists to end.
