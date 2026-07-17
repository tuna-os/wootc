# What if you don't want to use bootc?

wootc is built so the **Windows-side migration machinery is independent
of how Linux actually gets installed**. bootc/fisherman is just the
default *provisioner*. If you want to install a plain Debian, an Arch
system, a raw disk image, or your own distro's installer, you replace one
stage and keep everything else.

This guide shows the three ways to reuse the project without bootc:
adopt-and-configure, fork-the-provisioner, and use-as-a-library.

> Read [architecture-boundary.md](architecture-boundary.md) first — it
> defines the exact seam. This doc is the how-to.

## What you get for free (all distro-agnostic)

Everything here works regardless of the Linux you install:

- **The Wubi-style boot chain** — a signed shim→GRUB chain launched from
  the Windows Boot Manager (BCD one-shot), booting a kernel from the ESP.
  No repartitioning of the Windows OS volume.
- **NTFS-hosted root disk** — a VHDX/raw file on the Windows volume,
  attached at boot by the `99wootc-boot` dracut module (works for any
  initramfs that includes it).
- **The Windows installer GUI + headless CLI** — variant catalog, disk
  creation, ESP staging, BCD arming, credential vault, `state.json`
  lifecycle, themeable branding.
- **The User Data Bridge** — passthrough of Documents/Pictures/etc., Steam
  library reuse, browser/app import, MS Office → LibreOffice, wallpaper
  and theme migration, the reversible migration dashboard.
- **ESP kernel-sync** — keeps the Windows-ESP kernel current after OS
  updates, for BLS *and* classic `/boot` layouts.
- **The E2E harness** — Windows-in-a-VM, QGA control, serial capture,
  video-to-PR, the container-based migration tests.

None of the above mentions bootc. The only bootc-specific code lives in
one clearly-marked region of `payload/deployer/deploy.sh`.

## The provisioner contract

A provisioner turns an **attached empty block device + a recipe** into a
**bootable Linux root**. That is the whole interface.

**Input**
- an attached block device (loop or NBD), empty, ready to partition;
- a recipe: `{ source, hostname, filesystem, user{name,password_hash},
  flatpaks?, luks? }` — `source` is opaque (an OCI ref, an ISO path, a
  tarball URL, a debootstrap suite… whatever your provisioner understands).

**Output obligations**
1. A bootable root filesystem on the device (you own partitioning).
2. Kernel + initramfs at a discoverable path, for the ESP sync.
3. The kernel cmdline the installed system needs.
4. The `99wootc-boot` attach hook baked into that initramfs (the deployer
   ships the hook tree; your provisioner triggers the regeneration).
5. Optionally, a distro-signed shim+grub pair for the Secure Boot chain.

Everything else — disk discovery, NTFS mount, telemetry, vault
ingest/shred, User Data Bridge install, ESP sync mechanics, `state.json`,
reboot — is generic orchestration that stays.

## Option A — adopt and configure (no code)

If your distro ships a bootc-compatible image, you don't fork anything:
point `images.json` at your registry (see [branding.md](branding.md)) and
brand it. Done. This is the locked-down single-image onramp case.

## Option B — fork the provisioner

For a non-bootc install method, replace the marked provisioner region in
`deploy.sh`. Concretely:

1. Copy `payload/deployer/deploy.sh`. Everything **above** the
   `PROVISIONER: bootc/fisherman — begins here` banner and **below** the
   matching END banner is generic — leave it.
2. Replace the region between the banners with your installer. It receives
   `$LOOP_DEV` (the attached device) and the parsed recipe variables
   (`$IMAGE`/source, `$HOSTNAME`, `$FILESYSTEM`, vault user, …). Examples:
   - **debootstrap**: `parted`/`mkfs` the device, `debootstrap` a suite
     into it, install a kernel, `grub-install`, create the user.
   - **raw image**: `curl | dd` a prebuilt `.img` onto the device, grow
     the last partition.
   - **archinstall / distro installer**: drive it against `$LOOP_DEV`.
3. Satisfy the output obligations: make sure the installed initramfs
   contains the `99wootc-boot` hook (copy the tree from
   `/usr/lib/wootc/99wootc-boot/` and run your distro's initramfs tool),
   and report kernel/initramfs paths + cmdline the way the ESP-sync step
   expects (drop BLS entries, or adapt the sync's classic-layout branch —
   it already handles `/boot/vmlinuz-*`).
4. Rebuild the deployer initramfs (`payload/deployer/Containerfile`) with
   your provisioner's tools instead of podman/skopeo/fisherman.

The generic verification, ESP sync, User Data Bridge install, and reboot
all keep working unchanged.

## Option C — use the pieces as a library

You can also lift individual components into a different project:

- **Boot chain + BCD** (`app/installer_windows.go`) — Wubi-style
  Windows→Linux boot without repartitioning, independent of payload.
- **`99wootc-boot`** (`platform/dracut/`) — attach an NTFS-hosted
  VHDX/raw root at boot; drop-in dracut module.
- **User Data Bridge** (`payload/migration/`) — the passthrough, app/
  browser/Office import, and DE look migration are plain scripts keyed
  only on `/host/Users/<name>/`; nothing ties them to how the OS was
  installed. Reuse them under any Windows-adjacent Linux.
- **`wootc-esp-sync`** — self-healing ESP kernel sync for any
  ESP-booted-from-Windows layout.
- **The GUI** (`app/`) — a themeable Wails installer shell; swap the
  pipeline steps in `app/app.go` for your own.

## Licensing

Keep the upstream license and attribution when you fork or vendor pieces
(see the repo `LICENSE`). Contributions that generalize the provisioner
seam further are welcome upstream.

## When to upstream vs. fork

- New **generic** capability (a bridge category, a boot-chain fix, a DE in
  the look database) → upstream it; everyone benefits.
- A new **provisioner** → today, fork the region. Once a second
  provisioner exists in-tree we intend to extract
  `provisioners/<name>.sh` with a thin dispatch, at which point adding
  yours becomes dropping in one file. If you're building one, open an
  issue — that's the trigger to do the extraction.
