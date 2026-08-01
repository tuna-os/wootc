#!/bin/sh
# shellcheck disable=SC2154  # $final is exported into us by dracut's shutdown.sh
# shellcheck disable=SC3043  # `local` in #!/bin/sh: dracut's own shutdown.sh,
#                              which sources this hook, is #!/bin/sh and uses
#                              `local` throughout — every shell that runs it
#                              (bash, dash, busybox ash) supports it.
# /usr/lib/dracut/modules.d/99wootc-boot/wootc-umount-host.sh
#
# dracut SHUTDOWN hook: unmount the Windows host NTFS cleanly, after the
# Phase-2 root and its loop device are gone.
#
# Runs inside /run/initramfs after systemd-shutdown has pivoted out of the
# Phase-2 root (see wootc-stage-shutdown.sh, which makes that pivot possible
# in the first place). By this point dracut's shutdown.sh has already killed
# everything under /oldroot, unmounted it, and run `losetup -D` — so the loop
# device backed by root.disk is detached and the NTFS volume is finally
# unpinned. This is the last moment before `reboot -f -d -n`, and that `-n`
# means nothing else will sync for us.
#
# WHERE THE MOUNT IS BY NOW
# -------------------------
# The volume was mounted at /run/initramfs/wootc-host. Two path rewrites
# happen before this hook runs and neither leaves it under that name:
#   * systemd pivots into /run/initramfs, so the mount's path is rewritten
#     relative to the new root;
#   * shutdown.sh then does `mount --move /oldroot/run /oldsys/run`, landing
#     it at /oldsys/run/initramfs/wootc-host.
# dracut's own umount_a() only considers mount points whose path contains
# "oldroot", so /oldsys/... is invisible to it — this hook is the only thing
# that will unmount it. Rather than hard-code one of the possible spellings,
# match on the leaf name, which is stable under every rewrite.
#
# CONTRACT WITH shutdown.sh
# -------------------------
# The hook is sourced in a subshell and retried up to 40 times while it
# returns non-zero, then invoked once more with final="final". Returning 1 is
# how we wait for a still-busy volume; the retry budget is bounded by
# shutdown.sh, so we can never hang the reboot.
#
# Pure shell plus umount/losetup/sync only: at this point we are running out
# of a hand-staged tmpfs copy of the initramfs, and the initramfs a dracut
# base module guarantees has no grep, awk, sort or cut in it.

_wootc_umount_host() {
    # Defaults to the real thing; overridden only by
    # tests/unit/phase2-clean-ntfs-umount.bats, which runs this hook for real
    # against a fixture mount table. Nothing in the initramfs sets it.
    local procmounts="${WOOTC_SHUTDOWN_MOUNTS:-/proc/mounts}"

    _wootc_say() {
        echo "wootc: $*" > /dev/console 2> /dev/null || true
        echo "<27>wootc: $*" > /dev/kmsg 2> /dev/null || true
        [ -n "$WOOTC_SHUTDOWN_MOUNTS" ] && echo "wootc: $*"
        return 0
    }

    # Every mount point whose leaf name is wootc-host.
    _wootc_host_mounts() {
        local _dev _mp _rest
        while read -r _dev _mp _rest; do
            case "$_mp" in
                */wootc-host | wootc-host) printf '%s\n' "$_mp" ;;
            esac
        done < "$procmounts"
    }

    local mp left=0

    if [ -z "$(_wootc_host_mounts)" ]; then
        # Already gone: either a previous pass of this hook did it, or the
        # volume was never mounted on this boot. Either way we are done, and
        # returning 0 tells shutdown.sh to stop calling us.
        return 0
    fi

    # Detach anything still holding a file on the volume. shutdown.sh calls
    # this too, but only from umount_a(), which stops being called once it has
    # nothing left to unmount under /oldroot — and that can happen before the
    # last close on root.disk has landed.
    losetup -D 2> /dev/null || true
    sync 2> /dev/null || true

    for mp in $(_wootc_host_mounts); do
        if umount "$mp" 2> /dev/null; then
            _wootc_say "shutdown: unmounted the Windows host NTFS at $mp"
            continue
        fi
        if [ "$final" = "final" ]; then
            # Out of retries. A lazy unmount after an explicit sync at least
            # detaches the volume and flushes what we have, which is strictly
            # better for Windows than being left mounted rw, but it is NOT a
            # clean close — say so, because this line is the difference
            # between "Phase 2 handed C: back properly" and "chkdsk / Startup
            # Repair on the next Windows boot".
            sync 2> /dev/null || true
            umount -l "$mp" 2> /dev/null || true
            _wootc_say "shutdown: [WARN] host NTFS at $mp was still busy after every retry; lazy-detached — Windows may see a dirty volume"
            continue
        fi
        left=1
    done

    if [ "$left" = 1 ]; then
        # Busy. Return non-zero so shutdown.sh keeps us in the rotation and
        # calls us again after another umount/losetup sweep.
        return 1
    fi

    sync 2> /dev/null || true
    return 0
}

_wootc_umount_host
