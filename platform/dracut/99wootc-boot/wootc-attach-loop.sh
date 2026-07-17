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

modprobe ntfs3 2>/dev/null
modprobe nbd nbds_max=4 max_part=16 2>/dev/null

HOST_DEV="/dev/disk/by-uuid/$HOST_UUID"
[ -b "$HOST_DEV" ] || return 0

HOST_MNT="/run/initramfs/wootc-host"
mkdir -p "$HOST_MNT"

if ! mountpoint -q "$HOST_MNT"; then
    # Must be read-write: a read-only host mount would propagate a physical
    # write block through the loop device to the guest root filesystem.
    if ! mount -t ntfs3 -o rw,nobarrier,async,prealloc "$HOST_DEV" "$HOST_MNT"; then
        warn "wootc: cannot mount host NTFS rw — dirty volume? Boot Windows once and perform a full shutdown."
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
info "wootc: attached dynamic VHDX $FULL_LOOP_PATH as $LOOP_DEV (partitions scanned)"
return 0
