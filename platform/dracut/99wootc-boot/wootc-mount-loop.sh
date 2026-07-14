#!/bin/bash
# shellcheck disable=SC2154,SC2034,SC2168,SC1091  # root, rootok, local, /tmp/wootc.env are dracut env
# /usr/lib/dracut/modules.d/99wootc-boot/wootc-mount-loop.sh
# Hook 2: mount phase. When root="wootc" (set by the cmdline hook),
# mounts the Windows NTFS partition, binds root.disk to a loop device,
# and mounts it at $NEWROOT (/sysroot).

if [ "$root" = "wootc" ]; then
    if [ -f /tmp/wootc.env ]; then
        . /tmp/wootc.env
    fi

    if [ -z "$wootc_host_uuid" ] || [ -z "$wootc_loop_path" ]; then
        die "wootc: missing host UUID or loop path"
    fi

    info "wootc: initializing Windows loop-root storage pipeline..."

    modprobe ntfs3 2>/dev/null
    modprobe loop 2>/dev/null

    HOST_DEV="/dev/disk/by-uuid/$wootc_host_uuid"

    if [ ! -b "$HOST_DEV" ]; then
        info "wootc: waiting for host partition ($HOST_DEV)..."
        local i=0
        while [ ! -b "$HOST_DEV" ] && [ $i -lt 15 ]; do
            sleep 0.5
            i=$((i+1))
        done
    fi

    if [ ! -b "$HOST_DEV" ]; then
        die "wootc: host partition $HOST_DEV did not appear"
    fi

    HOST_MNT="/run/initramfs/wootc-host"
    mkdir -p "$HOST_MNT"

    # CRITICAL: must mount read-write. If the host is ro, the loop
    # device inherits the physical write block, rendering the guest
    # OS filesystem permanently read-only.
    info "wootc: mounting Windows partition ($HOST_DEV)..."
    if ! mount -t ntfs3 -o rw,nobarrier,async "$HOST_DEV" "$HOST_MNT"; then
        die "wootc: cannot mount host NTFS partition rw. " \
            "Windows may not have been shut down cleanly. " \
            "Please boot Windows once, perform a full shutdown " \
            "(not restart), and try again."
    fi

    FULL_LOOP_PATH="$HOST_MNT/$wootc_loop_path"
    FULL_LOOP_PATH=$(echo "$FULL_LOOP_PATH" | sed 's/\/\//\//g')

    if [ ! -f "$FULL_LOOP_PATH" ]; then
        die "wootc: root.disk not found at $FULL_LOOP_PATH"
    fi

    info "wootc: binding loop device to root.disk..."
    LOOP_DEV=$(losetup -f --show "$FULL_LOOP_PATH")
    if [ -z "$LOOP_DEV" ]; then
        die "wootc: losetup failed"
    fi

    blockdev --setra 2048 "$LOOP_DEV"

    info "wootc: mounting loop root to \$NEWROOT..."
    if ! mount -o rw,noatime "$LOOP_DEV" "$NEWROOT"; then
        die "wootc: failed to mount loop root"
    fi

    rootok=1
fi
