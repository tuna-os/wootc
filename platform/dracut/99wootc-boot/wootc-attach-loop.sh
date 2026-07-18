#!/bin/bash
# shellcheck disable=SC1091  # dracut-lib.sh is provided by the initramfs
# /usr/lib/dracut/modules.d/99wootc-boot/wootc-attach-loop.sh
# initqueue/settled hook: mount the Windows NTFS partition and attach
# root.vhdx as a partitioned NBD device. The target root partition's UUID
# then appears to udev, letting systemd's ordinary sysroot.mount (root=UUID=
# from the BLS entry / grub.cfg) and ostree-prepare-root proceed unchanged —
# no root= hijack required.
#
# initqueue hooks are re-run until the queue finishes, so every early-exit
# path returns 0 and the hook simply retries when devices appear later.

command -v getarg >/dev/null || . /lib/dracut-lib.sh

[ -e /run/wootc-loop-attached ] && return 0

LOOP_PATH=$(getarg loop=) || return 0
HOST_UUID=$(getarg wootc.host_uuid=) || return 0
[ -n "$LOOP_PATH" ] && [ -n "$HOST_UUID" ] || return 0

modprobe ntfs3 2>/dev/null   # kernel driver, if the target ships it
modprobe fuse  2>/dev/null   # for the ntfs-3g userspace fallback
modprobe nbd nbds_max=4 max_part=16 2>/dev/null

HOST_DEV="/dev/disk/by-uuid/$HOST_UUID"
[ -b "$HOST_DEV" ] || return 0

HOST_MNT="/run/initramfs/wootc-host"
mkdir -p "$HOST_MNT"

# Mount the host NTFS read-WRITE (a ro host mount would propagate a physical
# write barrier through the loop device to the guest root fs). Try the kernel
# driver first, then the ntfs-3g/lowntfs-3g FUSE drivers, because image support
# varies: some kernels build ntfs3 in (=y, so there is no .ko to find), some
# ship it as a module, some have neither and need userspace ntfs-3g. Probing at
# runtime is the only reliable answer — inspecting the image for a .ko file is
# not (that mistake produced a wrong root-cause diagnosis once already).
# Records which driver actually worked in NTFS_DRIVER. Worth logging: whether
# Phase-2 mounts via the kernel (ntfs3, possibly built in with no .ko) or the
# ntfs-3g FUSE fallback determines whether images need ntfs-3g injected at all.
NTFS_DRIVER=""
mount_host() {
    if mount -t ntfs3 -o rw,nobarrier,async,prealloc "$HOST_DEV" "$HOST_MNT" 2>/dev/null; then
        NTFS_DRIVER="kernel-ntfs3"; return 0
    fi
    local drv
    for drv in ntfs-3g lowntfs-3g mount.ntfs-3g; do
        command -v "$drv" >/dev/null 2>&1 || continue
        if "$drv" -o rw "$HOST_DEV" "$HOST_MNT" 2>/dev/null; then
            NTFS_DRIVER="fuse-$drv"; return 0
        fi
    done
    if mount -t ntfs -o rw "$HOST_DEV" "$HOST_MNT" 2>/dev/null; then
        NTFS_DRIVER="kernel-ntfs"; return 0
    fi
    return 1
}

if ! mountpoint -q "$HOST_MNT"; then
    if ! mount_host; then
        warn "wootc: cannot mount host NTFS rw (no ntfs3 and no ntfs-3g). Dirty volume? Boot Windows once and full-shutdown; and ensure the image has an NTFS driver."
        return 0
    fi
fi

FULL_LOOP_PATH="$HOST_MNT/${LOOP_PATH#/}"
if [ ! -f "$FULL_LOOP_PATH" ]; then
    warn "wootc: root.vhdx not found at $FULL_LOOP_PATH"
    return 0
fi

# VHDX must be attached by a format-aware block driver. qemu-nbd exposes it
# as a partitioned block device while preserving its metadata log semantics.
LOOP_DEV=/dev/nbd0
qemu-nbd --connect "$LOOP_DEV" --format=vhdx "$FULL_LOOP_PATH" || return 0
blockdev --setra 2048 "$LOOP_DEV" 2>/dev/null

: > /run/wootc-loop-attached
info "wootc: host NTFS mounted via ${NTFS_DRIVER:-unknown} (/proc/filesystems ntfs3: $(grep -cw ntfs3 /proc/filesystems 2>/dev/null))"
info "wootc: attached dynamic VHDX $FULL_LOOP_PATH as $LOOP_DEV (partitions scanned)"
return 0
