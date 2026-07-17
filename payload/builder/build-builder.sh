#!/usr/bin/env bash
# build-builder.sh — produce the Try-in-VM builder artifacts (SPEC §6.1):
#   builder-vmlinuz        (Alpine kernel)
#   builder-initramfs.img  (Alpine + podman + bootc + /init above)
#
# These get bundled under C:\wootc\qemu\ next to qemu-system-x86_64.exe; the
# Windows app boots them headless to build a preview disk from an OCI image.
#
# Runs in a Fedora/Alpine container with podman available. Output lands in
# ./out. Deliberately self-contained and reproducible — no network state beyond
# the Alpine package repos.
set -Eeuo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/out}"
ALPINE_VERSION="${ALPINE_VERSION:-3.21}"
mkdir -p "$OUT"

log() { printf '[build-builder] %s\n' "$*" >&2; }

# Build a minimal Alpine rootfs with the tools the /init needs, using podman.
# apk --initdb into a staging dir, install kernel + podman + bootc + util-linux,
# drop our /init in, then pack a newc cpio + gzip as the initramfs.
CID="wootc-builder-stage"
podman rm -f "$CID" >/dev/null 2>&1 || true

log "staging Alpine $ALPINE_VERSION rootfs with podman + bootc…"
podman run --name "$CID" "docker.io/library/alpine:$ALPINE_VERSION" sh -c '
    set -e
    apk add --no-cache \
        linux-virt \
        podman fuse-overlayfs \
        util-linux e2fsprogs xfsprogs btrfs-progs dosfstools \
        parted blkid \
        busybox \
        ca-certificates
    # bootc is not in Alpine repos; it travels inside the OCI image and is
    # invoked via `podman run ... bootc install`, so nothing to add here.
    ls /boot/vmlinuz-virt
'

ROOT="$OUT/rootfs"
rm -rf "$ROOT"; mkdir -p "$ROOT"
podman export "$CID" | tar -C "$ROOT" -xf -
podman rm -f "$CID" >/dev/null 2>&1 || true

# Extract the kernel from the staged rootfs.
cp "$ROOT/boot/vmlinuz-virt" "$OUT/builder-vmlinuz"

# Install our init as PID 1.
install -m755 "$HERE/wootc-builder-init" "$ROOT/init"

# Pack the initramfs (newc cpio + gzip).
log "packing initramfs…"
( cd "$ROOT" && find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -9 ) > "$OUT/builder-initramfs.img"

rm -rf "$ROOT"
log "done:"
ls -lh "$OUT/builder-vmlinuz" "$OUT/builder-initramfs.img" >&2
