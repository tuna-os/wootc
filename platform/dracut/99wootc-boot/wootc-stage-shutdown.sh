#!/bin/bash
# shellcheck disable=SC1091,SC2317  # dracut-lib.sh comes from the initramfs
# /usr/lib/dracut/modules.d/99wootc-boot/wootc-stage-shutdown.sh
#
# dracut PRE-PIVOT hook: stage a usable initramfs into /run/initramfs so that
# systemd-shutdown pivots back into it at reboot, which is the only place the
# Windows host NTFS can be unmounted cleanly.
#
# WHY THIS EXISTS
# ---------------
# Phase 2 runs its root filesystem out of a loop device backed by root.disk,
# which is a FILE ON THE WINDOWS NTFS VOLUME mounted rw at
# /run/initramfs/wootc-host. At shutdown that stack is self-pinning:
#
#     /            -> /dev/loop0p3   (XFS/ext4/btrfs, cannot unmount itself)
#     /dev/loop0   -> wootc-host/wootc/disks/root.disk
#     wootc-host   -> /dev/sdXn      (rw ntfs3)
#
# systemd's own last-ditch pass therefore reports, verbatim (fedora-gnome
# cells, run 30704513401):
#
#     (sd-remount)[...]: Failed to remount '/run/initramfs/wootc-host'
#                        read-only: Device or resource busy
#     systemd-shutdown[1]: Not all file systems unmounted, 1 left.
#     systemd-shutdown[1]: Not all loop devices detached, 1 left.
#     systemd-shutdown[1]: Cannot finalize remaining file systems, loop
#                          devices, continuing.
#     reboot: machine restart
#
# Windows then gets C: back with the volume never closed out. Observed
# consequence: the desktop appears for ~26s, the box reboots itself, loops
# through "Windows Boot Manager" three or four times, and lands in Startup
# Repair with "your device ran into a problem and couldn't be repaired" — so
# the harness's QGA wait for the Windows return times out after 10 minutes.
# The deployer already enforces exactly this invariant for its own teardown
# (deploy.sh, "a still-mounted rw NTFS would be flagged dirty"); Phase 2 had
# no equivalent, and this hook plus wootc-umount-host.sh is that equivalent.
#
# The escape hatch systemd offers is switch_root_initramfs(): if
# /run/initramfs/shutdown is executable, PID 1 pivots into /run/initramfs and
# hands off to it, at which point / and /usr are no longer the loop device and
# the whole stack can be torn down in order. dracut normally populates
# /run/initramfs from /boot/initramfs-$(uname -r).img via
# dracut-shutdown.service -> dracut-initramfs-restore. ON AN OSTREE/COMPOSEFS
# DEPLOYMENT THAT FILE DOES NOT EXIST, dracut-initramfs-restore silently
# no-ops, /run/initramfs/shutdown is never created, and no pivot happens —
# which is why the trace above shows systemd giving up rather than "Returning
# to initrd..." So we stage /run/initramfs ourselves, from the initramfs we
# are *currently running in*, while it is still there to copy.
#
# FAIL-SAFE BY CONSTRUCTION
# -------------------------
# Every failure path ends by deleting /run/initramfs/shutdown and dropping the
# staged tree. Without an executable /run/initramfs/shutdown systemd does not
# pivot, which is precisely today's behaviour — so a broken or partial staging
# can only reproduce the current bug, never invent a new failure mode.
#
# THIS FILE IS SOURCED, NOT EXECUTED (dracut's source_hook uses `.`), so it
# must never call `exit` — that would take dracut-pre-pivot down with it.
# Everything lives in a function and every exit path is a `return`.

_wootc_stage_shutdown() {
    # The four paths this hook touches, as variables with their real defaults.
    # Nothing in the initramfs ever sets the overrides — they exist so
    # tests/unit/phase2-clean-ntfs-umount.bats can run this function for real
    # against a sandbox tree instead of asserting on its source text. A hook
    # that only ever gets grepped is a hook nobody has proven works, and this
    # one runs exactly once per Phase-2 boot with no second chance.
    local root="${WOOTC_STAGE_ROOT:-}"
    local dst="${WOOTC_STAGE_DST:-/run/initramfs}"
    local procmounts="${WOOTC_STAGE_MOUNTS:-/proc/mounts}"
    local meminfo="${WOOTC_STAGE_MEMINFO:-/proc/meminfo}"
    local host_mnt="$dst/wootc-host"
    local e name

    _wootc_say() {
        echo "wootc: $*" > /dev/console 2>/dev/null || true
        echo "<27>wootc: $*" > /dev/kmsg 2>/dev/null || true
        [ -n "$WOOTC_STAGE_DST" ] && echo "wootc: $*"
        return 0
    }

    # Undo a partial staging. NEVER touches wootc-host: that is the live rw
    # NTFS mount this whole exercise exists to protect, and it lives inside
    # the directory we are cleaning. A blanket `rm -rf $dst` here would delete
    # into the Windows volume.
    _wootc_unstage() {
        local victim
        for victim in "$dst"/*; do
            [ -e "$victim" ] || continue
            case "${victim##*/}" in
                wootc-host) continue ;;
            esac
            rm -rf "$victim" 2>/dev/null || true
        done
        rm -f "$dst/shutdown" 2>/dev/null || true
    }

    # Copy the children of $1 into $2, skipping the names listed in $3. Used
    # to descend past /usr/lib/{modules,firmware} without ever copying them:
    # a copy-then-delete would transiently double the largest thing in the
    # initramfs in RAM, on a box that is already mid-shutdown.
    _wootc_copy_children() {
        local src="$1" out="$2" skip=" $3 " child base
        mkdir -p "$out" || return 1
        for child in "$src"/*; do
            [ -e "$child" ] || [ -L "$child" ] || continue
            base="${child##*/}"
            case "$skip" in
                *" $base "*) continue ;;
            esac
            cp -a "$child" "$out/" || return 1
        done
        return 0
    }

    # 1. Only ever act on a Phase-2 wootc boot. If the host NTFS is not
    #    mounted there is nothing that needs a pivot, and staging one would be
    #    pure added risk on every other boot of this image.
    local _dev _mp _rest mounted=0
    while read -r _dev _mp _rest; do
        [ "$_mp" = "$host_mnt" ] && { mounted=1; break; }
    done < "$procmounts"
    if [ "$mounted" != 1 ]; then
        return 0
    fi

    # 2. If dracut-shutdown.service already restored a real initramfs — a
    #    non-ostree layout where /boot/initramfs-$(uname -r).img does exist —
    #    leave it alone. That image was built from this same dracut module, so
    #    it already carries the shutdown hook, and overwriting a tree systemd
    #    is about to pivot into would be gratuitous risk.
    if [ -x "$dst/shutdown" ]; then
        _wootc_say "shutdown-stage: /run/initramfs already populated by dracut; leaving it"
        return 0
    fi

    # 3. Do not push a shutting-down box into OOM. The staged tree is a tmpfs
    #    copy of the initramfs minus modules and firmware — tens of MB — so
    #    half a gig of headroom is a generous floor, and falling under it just
    #    means we behave exactly as we do today.
    local memavail="" _k _v
    while read -r _k _v _rest; do
        [ "$_k" = "MemAvailable:" ] && { memavail="$_v"; break; }
    done < "$meminfo"
    if [ -n "$memavail" ] && [ "$memavail" -lt 524288 ]; then
        _wootc_say "shutdown-stage: only ${memavail}kB available; skipping the initramfs staging (host NTFS will not be unmounted cleanly)"
        return 0
    fi

    # 4. Copy the live initramfs into /run/initramfs. /run is a tmpfs that
    #    systemd carries across the pivot, so this survives; the initramfs
    #    root itself does not (switch-root frees it).
    #
    #    Skips: the kernel/api filesystems, the real root, and /run itself —
    #    copying /run would recurse into the destination and into the mounted
    #    Windows volume.
    local skip_top="proc sys dev run tmp mnt sysroot oldroot oldsys usr lib lib64"
    mkdir -p "$dst" || { _wootc_say "shutdown-stage: cannot create $dst"; return 0; }

    for e in "$root"/*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        name="${e##*/}"
        case " $skip_top " in
            *" $name "*) continue ;;
        esac
        if ! cp -a "$e" "$dst/"; then
            _wootc_say "shutdown-stage: failed copying /$name into $dst — abandoning the staging"
            _wootc_unstage
            return 0
        fi
    done

    # /usr, /lib and /lib64 are handled by descent so the module and firmware
    # trees are never copied at all. When they are symlinks (usr-merge) cp -a
    # reproduces the link and the descent is skipped.
    for name in usr lib lib64; do
        e="$root/$name"
        [ -e "$e" ] || continue
        if [ -L "$e" ]; then
            cp -a "$e" "$dst/" || { _wootc_unstage; return 0; }
            continue
        fi
        [ -d "$e" ] || continue
        # "lib" is held back so /usr/lib is descended into rather than copied
        # wholesale — that is where the module tree lives.
        if ! _wootc_copy_children "$e" "$dst/$name" "modules firmware lib"; then
            _wootc_say "shutdown-stage: failed copying $e into $dst — abandoning the staging"
            _wootc_unstage
            return 0
        fi
        [ -e "$e/lib" ] || continue
        if [ -L "$e/lib" ]; then
            cp -a "$e/lib" "$dst/$name/" || { _wootc_unstage; return 0; }
        elif ! _wootc_copy_children "$e/lib" "$dst/$name/lib" "modules firmware"; then
            _wootc_say "shutdown-stage: failed copying $e/lib into $dst — abandoning the staging"
            _wootc_unstage
            return 0
        fi
    done

    # 4b. Mount points and a minimal /dev, because we deliberately did not copy
    #     either. systemd's switch_root() moves /sys, /dev, /run and /proc into
    #     the new root before pivoting and needs the directories to exist to do
    #     it; /oldroot and /oldsys are where the old tree and dracut's
    #     shutdown.sh put things afterwards. The static device nodes are the
    #     same handful dracut bakes into a real initramfs image — insurance for
    #     the log channel, since a missing /dev/console would silently turn
    #     every diagnostic below into a regular file nobody ever reads.
    mkdir -p "$dst/proc" "$dst/sys" "$dst/dev" "$dst/run" \
             "$dst/oldroot" "$dst/oldsys" 2>/dev/null || true
    [ -e "$dst/dev/console" ] || mknod -m 0600 "$dst/dev/console" c 5 1 2>/dev/null || true
    [ -e "$dst/dev/kmsg" ]    || mknod -m 0600 "$dst/dev/kmsg"    c 1 11 2>/dev/null || true
    [ -e "$dst/dev/null" ]    || mknod -m 0666 "$dst/dev/null"    c 1 3 2>/dev/null || true

    # 5. VERIFY the staged tree can actually do the job, and unstage it if it
    #    cannot. `-x $dst/shutdown` is the exact predicate systemd tests, so
    #    checking anything weaker would let a useless tree take over shutdown.
    if [ ! -x "$dst/shutdown" ]; then
        _wootc_say "shutdown-stage: no executable $dst/shutdown after staging — reverting"
        _wootc_unstage
        return 0
    fi
    local hookdst="" cand
    for e in "$dst/lib/dracut/hooks/shutdown" "$dst/usr/lib/dracut/hooks/shutdown"; do
        [ -d "$e" ] || continue
        # A hook directory with no wootc hook in it means the pivot would
        # happen and STILL leave the NTFS mounted — worse than not pivoting.
        for cand in "$e"/*wootc-umount-host.sh; do
            [ -f "$cand" ] || continue
            hookdst="$e"
            break
        done
        [ -n "$hookdst" ] && break
    done
    if [ -z "$hookdst" ]; then
        _wootc_say "shutdown-stage: staged initramfs carries no wootc-umount-host shutdown hook — reverting"
        _wootc_unstage
        return 0
    fi

    _wootc_say "shutdown-stage: staged $dst for the shutdown pivot (hook: ${hookdst#"$dst"}/*wootc-umount-host.sh)"
    return 0
}

_wootc_stage_shutdown
