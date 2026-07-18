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

# say() — logging that is actually VISIBLE on the serial console.
#
# Do NOT use dracut's info()/warn() for anything we need to diagnose a failed
# boot. Both go through printk and are silently filtered:
#   info() writes <30> (KERN_INFO, level 6) and only echoes to stderr when
#     DRACUT_QUIET != yes — and check_quiet() defaults DRACUT_QUIET to "yes"
#     unless rd.info/rd.debug is on the cmdline;
#   warn() writes <28> (KERN_WARNING, level 4), and `quiet` sets
#     console_loglevel=4 while printk prints only levels STRICTLY BELOW it —
#     so warn is suppressed too.
# The Phase-2 cmdline also differs by boot path (the GRUB path adds
# ignore_loglevel, the BLS path does not), so the printk threshold is not
# something we can rely on. Writing straight to /dev/console bypasses printk
# filtering entirely — this is how systemd's "Entering emergency mode" reaches
# the serial log, the one Phase-2 line we ever actually saw.
# We ALSO emit at <27> (KERN_ERR, level 3) so the line lands in the journal and
# survives below any plausible console_loglevel.
say() {
    echo "wootc: $*" > /dev/console 2>/dev/null || true
    echo "<27>wootc: $*" > /dev/kmsg 2>/dev/null || true
}

# Every early return below is a distinct diagnosis. Previously they were all
# silent `return 0`, which made "hook absent", "hook exited early" and "hook ran
# but its output was filtered" indistinguishable from the serial log — each
# costing a full VM run to tell apart. Announce entry and every exit reason.
say "attach-loop hook entered (initqueue/settled)"

[ -e /run/wootc-loop-attached ] && return 0

LOOP_PATH=$(getarg loop=)
HOST_UUID=$(getarg wootc.host_uuid=)
if [ -z "$LOOP_PATH" ] || [ -z "$HOST_UUID" ]; then
    say "EXIT: missing kernel args (loop='${LOOP_PATH}' wootc.host_uuid='${HOST_UUID}') — the BLS entry/grub.cfg did not carry them"
    return 0
fi

modprobe ntfs3 2>/dev/null   # kernel driver, if the target ships it
modprobe fuse  2>/dev/null   # for the ntfs-3g userspace fallback
modprobe nbd nbds_max=4 max_part=16 2>/dev/null

HOST_DEV="/dev/disk/by-uuid/$HOST_UUID"
if [ ! -b "$HOST_DEV" ]; then
    # Not necessarily fatal: initqueue hooks re-run until the queue drains, so
    # the host partition may simply not have shown up to udev yet. But if this
    # is the LAST thing in the log, the device never appeared at all.
    say "waiting: host NTFS $HOST_DEV not present yet (initqueue will retry)"
    return 0
fi

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
        say "EXIT: cannot mount host NTFS rw (no ntfs3, no ntfs-3g). Dirty volume? Boot Windows once and full-shutdown; and ensure the image has an NTFS driver. /proc/filesystems ntfs3=$(grep -cw ntfs3 /proc/filesystems 2>/dev/null) ntfs-3g=$(command -v ntfs-3g >/dev/null 2>&1 && echo yes || echo no)"
        return 0
    fi
fi
say "host NTFS mounted via ${NTFS_DRIVER:-unknown}"

FULL_LOOP_PATH="$HOST_MNT/${LOOP_PATH#/}"
if [ ! -f "$FULL_LOOP_PATH" ]; then
    say "EXIT: root.vhdx not found at $FULL_LOOP_PATH (host NTFS mounted OK, so the path or the deploy is wrong)"
    return 0
fi

# VHDX must be attached by a format-aware block driver. qemu-nbd exposes it
# as a partitioned block device while preserving its metadata log semantics.
LOOP_DEV=/dev/nbd0
if ! qemu-nbd --connect "$LOOP_DEV" --format=vhdx "$FULL_LOOP_PATH"; then
    say "EXIT: qemu-nbd failed to attach $FULL_LOOP_PATH as $LOOP_DEV (nbd module loaded=$(grep -cw nbd /proc/modules 2>/dev/null), qemu-nbd=$(command -v qemu-nbd >/dev/null 2>&1 && echo yes || echo no))"
    return 0
fi
blockdev --setra 2048 "$LOOP_DEV" 2>/dev/null

: > /run/wootc-loop-attached
say "attached dynamic VHDX $FULL_LOOP_PATH as $LOOP_DEV"
# The whole point of the attach: the root partition's UUID must now appear to
# udev, or sysroot.mount still fails and we land in the emergency shell with the
# attach looking successful. Report what actually showed up.
say "post-attach partitions: $(ls /dev/nbd0p* 2>/dev/null | tr '\n' ' ')"
say "post-attach by-uuid: $(ls /dev/disk/by-uuid/ 2>/dev/null | tr '\n' ' ')"
return 0
