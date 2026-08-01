#!/usr/bin/env bats
# Phase 2 must hand the Windows volume back CLOSED, not merely stop using it.
#
# The bug (run 30704513401, `fedora-gnome-win11pro` and
# `fedora-gnome-win11pro-btrfs`, identical traces — so not a flake): Phase-2
# Linux boots, passes every passthrough and user-data check, and reboots. Its
# root lives on a loop device backed by root.disk, a file on the rw NTFS mount
# at /run/initramfs/wootc-host, so the stack pins itself and systemd's last
# pass gives up verbatim:
#
#     Failed to remount '/run/initramfs/wootc-host' read-only: Device or
#         resource busy
#     Not all file systems unmounted, 1 left.
#     Not all loop devices detached, 1 left.
#     Cannot finalize remaining file systems, loop devices, continuing.
#     reboot: machine restart
#
# Windows then shows a desktop for ~26s, reboots itself, loops the boot
# manager three or four times and dies in Startup Repair — so the harness's
# QGA wait for the Windows return times out at 10 minutes. Every cell that
# mounts the host volume with kernel ntfs3 failed this way; the cells that
# fall back to the ntfs-3g FUSE driver did not, which is why the bug looked
# image-specific rather than structural.
#
# The escape hatch is systemd's switch_root_initramfs(): with an executable
# /run/initramfs/shutdown, PID 1 pivots back into an initramfs where / is no
# longer the loop device. dracut normally fills /run/initramfs from
# /boot/initramfs-$(uname -r).img — a file that DOES NOT EXIST on ostree or
# composefs, so dracut-initramfs-restore no-ops and no pivot ever happens.
# Hence two hooks: pre-pivot stages /run/initramfs from the live initramfs,
# and shutdown unmounts the volume once the loop is detached.
#
# The tests below run both hooks for real. A hook that is only grepped is a
# hook nobody has proven works, and these two get exactly one shot per boot.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    MODDIR="$REPO_ROOT/platform/dracut/99wootc-boot"
    STAGE="$MODDIR/wootc-stage-shutdown.sh"
    UMOUNT_HOOK="$MODDIR/wootc-umount-host.sh"
    MODSETUP="$MODDIR/module-setup.sh"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    DEPMOD="$REPO_ROOT/payload/deployer/module-setup.sh"
    CFILE="$REPO_ROOT/payload/deployer/Containerfile"
}

# ── Static wiring ───────────────────────────────────────────────────────────

@test "both hooks are syntactically valid and safe to SOURCE" {
    run bash -n "$STAGE";        [ "$status" -eq 0 ]
    run bash -n "$UMOUNT_HOOK";  [ "$status" -eq 0 ]
    run bash -n "$MODSETUP";     [ "$status" -eq 0 ]
    run bash -n "$DEPLOY";       [ "$status" -eq 0 ]
    # dracut sources hooks (`. "$__f"`). A top-level `exit` in the pre-pivot
    # hook would take dracut-pre-pivot down with it and abort the boot.
    run grep -nE '^[[:space:]]*exit( |$)' "$STAGE"
    [ "$status" -ne 0 ]
    run grep -nE '^[[:space:]]*exit( |$)' "$UMOUNT_HOOK"
    [ "$status" -ne 0 ]
}

@test "the dracut module registers both hooks under the exact expected names" {
    grep -q 'inst_hook pre-pivot 99 "\$moddir/wootc-stage-shutdown.sh"' "$MODSETUP"
    grep -q 'inst_hook shutdown 50 "\$moddir/wootc-umount-host.sh"' "$MODSETUP"
    # inst_hook dfatals on a missing SOURCE but says nothing about a hook that
    # failed to land, and an absent shutdown hook is invisible until Windows
    # will not boot. The module must verify the installed paths.
    grep -q 'lib/dracut/hooks/pre-pivot/99-wootc-stage-shutdown.sh' "$MODSETUP"
    grep -q 'lib/dracut/hooks/shutdown/50-wootc-umount-host.sh' "$MODSETUP"
    grep -q 'dfatal .*did not install into the initramfs' "$MODSETUP"
    # `reboot -f -d -n` does not sync; the hooks call it themselves.
    grep -qE 'inst_multiple .*\bsync\b' "$MODSETUP"
}

@test "the early-cpio overlay carries both hooks, and refuses to build without them" {
    # The branches that cannot regenerate the target initramfs get their hooks
    # from stage_wootc_overlay, not from dracut — so assert against that
    # function's body, not against the file. The same two path strings also
    # appear in build_phase2_initrd's gate, and a file-wide grep would happily
    # pass on an overlay builder that stages nothing.
    local overlay_fn
    overlay_fn=$(awk '/^stage_wootc_overlay\(\) \{/,/^\}/' "$DEPLOY")
    echo "$overlay_fn" | grep -q 'usr/lib/dracut/hooks/pre-pivot/99-wootc-stage-shutdown.sh'
    echo "$overlay_fn" | grep -q 'usr/lib/dracut/hooks/shutdown/50-wootc-umount-host.sh'
    echo "$overlay_fn" | grep -q 'wootc/99wootc-boot/wootc-stage-shutdown.sh'
    echo "$overlay_fn" | grep -q 'wootc/99wootc-boot/wootc-umount-host.sh'
    grep -q 'carries no Phase-2 shutdown hooks' "$DEPLOY"
    # /usr/lib, never a real /lib: an early cpio creating /lib as a directory
    # collides with the base initrd's /lib -> usr/lib symlink.
    run grep -nE '\$ovl/lib/dracut/hooks' "$DEPLOY"
    [ "$status" -ne 0 ]
    # And the files have to reach the deployer initramfs to be stageable.
    grep -q 'inst /usr/lib/wootc/99wootc-boot/wootc-stage-shutdown.sh' "$DEPMOD"
    grep -q 'inst /usr/lib/wootc/99wootc-boot/wootc-umount-host.sh' "$DEPMOD"
    grep -q 'wootc-stage-shutdown.sh' "$CFILE"
    grep -q 'wootc-umount-host.sh' "$CFILE"
}

@test "the overlay completeness gate actually rejects a hookless overlay" {
    # Behavioural, against the real build_phase2_initrd: a mutation that drops
    # the shutdown hooks must be fatal BEFORE anything is packed.
    command -v cpio >/dev/null || skip "cpio unavailable"
    ovl="$BATS_TEST_TMPDIR/ovl"
    mkdir -p "$ovl/usr/lib/systemd/system/initrd-root-device.target.wants" \
             "$ovl/usr/lib/wootc" \
             "$ovl/usr/lib/dracut/hooks/pre-pivot" \
             "$ovl/usr/lib/dracut/hooks/shutdown"
    echo unit > "$ovl/usr/lib/systemd/system/wootc-attach.service"
    ln -sf ../wootc-attach.service \
        "$ovl/usr/lib/systemd/system/initrd-root-device.target.wants/wootc-attach.service"
    printf '#!/bin/bash\n' > "$ovl/usr/lib/wootc/wootc-attach-loop.sh"
    install -m0755 "$STAGE" "$ovl/usr/lib/dracut/hooks/pre-pivot/99-wootc-stage-shutdown.sh"
    install -m0755 "$UMOUNT_HOOK" "$ovl/usr/lib/dracut/hooks/shutdown/50-wootc-umount-host.sh"
    chmod +x "$ovl/usr/lib/wootc/wootc-attach-loop.sh"
    ( cd "$BATS_TEST_TMPDIR" && echo x > tool && find . | cpio -o -H newc --quiet ) \
        > "$BATS_TEST_TMPDIR/base.img" 2>/dev/null

    build() {
        bash -c "
            log() { echo \"LOG: \$*\"; }
            err() { echo \"ERR: \$*\" >&2; }
            $(awk '/^build_phase2_initrd\(\) \{/,/^\}/' "$DEPLOY")
            build_phase2_initrd '$ovl' '$BATS_TEST_TMPDIR/base.img' '$1'
        "
    }

    run build "$BATS_TEST_TMPDIR/ok.img"
    [ "$status" -eq 0 ]

    rm "$ovl/usr/lib/dracut/hooks/shutdown/50-wootc-umount-host.sh"
    run build "$BATS_TEST_TMPDIR/bad.img"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'no Phase-2 shutdown hooks'
    [ ! -e "$BATS_TEST_TMPDIR/bad.img" ]
}

# ── Behavioural: the pre-pivot staging hook ─────────────────────────────────

# A miniature initramfs: /shutdown, a couple of tool dirs, the shutdown hook
# where dracut puts it, and a module tree that must NOT be copied.
make_fake_initramfs() { # <root>
    local r="$1"
    mkdir -p "$r/usr/bin" "$r/usr/sbin" "$r/etc" \
             "$r/usr/lib/dracut/hooks/shutdown" \
             "$r/usr/lib/dracut/hooks/pre-pivot" \
             "$r/usr/lib/modules/6.1.0/kernel" \
             "$r/usr/lib/firmware"
    printf '#!/bin/sh\n' > "$r/shutdown"
    chmod +x "$r/shutdown"
    printf '#!/bin/sh\n' > "$r/usr/bin/bash"; chmod +x "$r/usr/bin/bash"
    echo x > "$r/etc/fstab"
    ln -sf usr/lib "$r/lib"
    install -m0755 "$UMOUNT_HOOK" "$r/usr/lib/dracut/hooks/shutdown/50-wootc-umount-host.sh"
    head -c 200000 /dev/zero > "$r/usr/lib/modules/6.1.0/kernel/big.ko"
    head -c 200000 /dev/zero > "$r/usr/lib/firmware/blob.bin"
}

make_fixtures() { # <dst> <host-mounted:yes|no> <memavail-kB>
    FIX="$BATS_TEST_TMPDIR/fix"
    mkdir -p "$FIX"
    MOUNTS="$FIX/mounts"
    MEMINFO="$FIX/meminfo"
    {
        echo "proc /proc proc rw 0 0"
        [ "$2" = yes ] && echo "/dev/sda3 $1/wootc-host ntfs3 rw 0 0"
    } > "$MOUNTS"
    printf 'MemTotal:       4000000 kB\nMemAvailable:   %s kB\n' "$3" > "$MEMINFO"
}

run_stage() { # <root> <dst>
    env WOOTC_STAGE_ROOT="$1" WOOTC_STAGE_DST="$2" \
        WOOTC_STAGE_MOUNTS="$MOUNTS" WOOTC_STAGE_MEMINFO="$MEMINFO" \
        bash -c ". '$STAGE'"
}

@test "behavioral: nothing is staged when the host NTFS is not mounted" {
    root="$BATS_TEST_TMPDIR/r1"; dst="$BATS_TEST_TMPDIR/d1"
    make_fake_initramfs "$root"; mkdir -p "$dst"
    make_fixtures "$dst" no 2000000
    run run_stage "$root" "$dst"
    [ "$status" -eq 0 ]
    # Not a wootc boot: the pivot must not be armed on somebody else's system.
    [ ! -e "$dst/shutdown" ]
    [ -z "$(ls -A "$dst")" ]
}

@test "behavioral: a Phase-2 boot stages an initramfs that systemd will pivot into" {
    root="$BATS_TEST_TMPDIR/r2"; dst="$BATS_TEST_TMPDIR/d2"
    make_fake_initramfs "$root"
    # The live rw NTFS mount lives INSIDE the directory being staged.
    mkdir -p "$dst/wootc-host/wootc/disks"
    echo rootdisk > "$dst/wootc-host/wootc/disks/root.disk"
    make_fixtures "$dst" yes 2000000

    run run_stage "$root" "$dst"
    [ "$status" -eq 0 ]
    # systemd's exact predicate for switch_root_initramfs().
    [ -x "$dst/shutdown" ]
    # ...and something in there that unmounts the volume once we are pivoted.
    [ -f "$dst/usr/lib/dracut/hooks/shutdown/50-wootc-umount-host.sh" ]
    [ -x "$dst/usr/bin/bash" ]
    [ -L "$dst/lib" ]
    # Mount points systemd needs to move /proc, /sys, /dev, /run across.
    [ -d "$dst/proc" ] && [ -d "$dst/sys" ] && [ -d "$dst/dev" ] && [ -d "$dst/run" ]
    # The volume we are protecting is untouched.
    [ -f "$dst/wootc-host/wootc/disks/root.disk" ]
    # Modules and firmware are never copied — not copied-then-deleted, which
    # would transiently double the biggest thing in RAM mid-shutdown.
    [ ! -e "$dst/usr/lib/modules" ]
    [ ! -e "$dst/usr/lib/firmware" ]
    [ -d "$dst/usr/lib/dracut" ]
}

@test "behavioral: an initramfs with no /shutdown arms nothing (fail-safe)" {
    root="$BATS_TEST_TMPDIR/r3"; dst="$BATS_TEST_TMPDIR/d3"
    make_fake_initramfs "$root"
    rm "$root/shutdown"
    mkdir -p "$dst/wootc-host"; echo keep > "$dst/wootc-host/sentinel"
    make_fixtures "$dst" yes 2000000

    run run_stage "$root" "$dst"
    [ "$status" -eq 0 ]
    # Without an executable /run/initramfs/shutdown systemd simply does not
    # pivot, which is exactly today's behaviour — a half-staged tree must
    # never be left behind pretending otherwise.
    [ ! -e "$dst/shutdown" ]
    [ ! -e "$dst/usr" ]
    # And the cleanup must never delete into the Windows volume.
    [ -f "$dst/wootc-host/sentinel" ]
}

@test "behavioral: a staged tree carrying no umount hook is reverted" {
    root="$BATS_TEST_TMPDIR/r4"; dst="$BATS_TEST_TMPDIR/d4"
    make_fake_initramfs "$root"
    rm "$root/usr/lib/dracut/hooks/shutdown/50-wootc-umount-host.sh"
    mkdir -p "$dst/wootc-host"; echo keep > "$dst/wootc-host/sentinel"
    make_fixtures "$dst" yes 2000000

    run run_stage "$root" "$dst"
    [ "$status" -eq 0 ]
    # Pivoting into an initramfs that does NOT unmount the volume is worse
    # than not pivoting: same dirty NTFS, plus a whole extra shutdown path.
    [ ! -e "$dst/shutdown" ]
    [ -f "$dst/wootc-host/sentinel" ]
    echo "$output" | grep -q 'reverting'
}

@test "behavioral: staging is skipped rather than risking OOM on a low-memory box" {
    root="$BATS_TEST_TMPDIR/r5"; dst="$BATS_TEST_TMPDIR/d5"
    make_fake_initramfs "$root"; mkdir -p "$dst/wootc-host"
    make_fixtures "$dst" yes 100000

    run run_stage "$root" "$dst"
    [ "$status" -eq 0 ]
    [ ! -e "$dst/shutdown" ]
    echo "$output" | grep -q 'skipping the initramfs staging'
}

@test "behavioral: an already-populated /run/initramfs is left alone" {
    root="$BATS_TEST_TMPDIR/r6"; dst="$BATS_TEST_TMPDIR/d6"
    make_fake_initramfs "$root"
    mkdir -p "$dst/wootc-host"
    printf '#!/bin/sh\n' > "$dst/shutdown"; chmod +x "$dst/shutdown"
    echo original > "$dst/marker"
    make_fixtures "$dst" yes 2000000

    run run_stage "$root" "$dst"
    [ "$status" -eq 0 ]
    [ -f "$dst/marker" ]
    [ ! -e "$dst/usr" ]
}

# ── Behavioural: the shutdown hook ──────────────────────────────────────────

make_stubs() { # <umount-exit-code>
    STUBS="$BATS_TEST_TMPDIR/stubs.$1.$RANDOM"
    STUBLOG="$STUBS/log"
    mkdir -p "$STUBS"
    : > "$STUBLOG"
    cat > "$STUBS/umount" <<EOF
#!/bin/sh
echo "umount \$*" >> "$STUBLOG"
[ "\$1" = "-l" ] && exit 0
exit $1
EOF
    cat > "$STUBS/losetup" <<EOF
#!/bin/sh
echo "losetup \$*" >> "$STUBLOG"
EOF
    cat > "$STUBS/sync" <<EOF
#!/bin/sh
echo "sync" >> "$STUBLOG"
EOF
    chmod +x "$STUBS"/umount "$STUBS"/losetup "$STUBS"/sync
}

run_umount_hook() { # <mounts-file> <final|"">
    env PATH="$STUBS:$PATH" WOOTC_SHUTDOWN_MOUNTS="$1" final="$2" \
        bash -c ". '$UMOUNT_HOOK'"
}

@test "behavioral: the volume is found at the path dracut's shutdown.sh leaves it" {
    # shutdown.sh does `mount --move /oldroot/run /oldsys/run`, and its own
    # umount_a() only considers mount points containing "oldroot" — so
    # /oldsys/... is invisible to dracut and this hook is the only thing that
    # will ever unmount it.
    make_stubs 0
    m="$BATS_TEST_TMPDIR/m-oldsys"
    printf '/dev/sda3 /oldsys/run/initramfs/wootc-host ntfs3 rw 0 0\n' > "$m"
    run run_umount_hook "$m" ""
    [ "$status" -eq 0 ]
    grep -q 'umount /oldsys/run/initramfs/wootc-host' "$STUBLOG"
    grep -q '^sync' "$STUBLOG"
    echo "$output" | grep -q 'unmounted the Windows host NTFS'
}

@test "behavioral: the other post-pivot spellings are found too" {
    for path in /oldroot/run/initramfs/wootc-host /run/initramfs/wootc-host /wootc-host; do
        make_stubs 0
        m="$BATS_TEST_TMPDIR/m-any"
        printf '/dev/sda3 %s ntfs3 rw 0 0\n' "$path" > "$m"
        run run_umount_hook "$m" ""
        [ "$status" -eq 0 ]
        grep -q "umount $path" "$STUBLOG"
    done
}

@test "behavioral: a busy volume asks to be retried instead of being abandoned" {
    # shutdown.sh re-runs a non-zero hook up to 40 times, sweeping umounts and
    # `losetup -D` in between — which is exactly how the loop backing root.disk
    # eventually goes away. Returning 0 here would throw that budget away.
    make_stubs 32
    m="$BATS_TEST_TMPDIR/m-busy"
    printf '/dev/sda3 /oldsys/run/initramfs/wootc-host ntfs3 rw 0 0\n' > "$m"
    run run_umount_hook "$m" ""
    [ "$status" -eq 1 ]
    ! echo "$output" | grep -q 'lazy-detached'
}

@test "behavioral: the final pass syncs and lazy-detaches rather than leaving it mounted" {
    make_stubs 32
    m="$BATS_TEST_TMPDIR/m-final"
    printf '/dev/sda3 /oldsys/run/initramfs/wootc-host ntfs3 rw 0 0\n' > "$m"
    run run_umount_hook "$m" "final"
    [ "$status" -eq 0 ]
    grep -q 'umount -l /oldsys/run/initramfs/wootc-host' "$STUBLOG"
    grep -q '^sync' "$STUBLOG"
    # A lazy detach is NOT a clean close; the serial log must say so, or the
    # next Windows boot's chkdsk looks like a fresh mystery.
    echo "$output" | grep -q 'WARN'
    echo "$output" | grep -q 'dirty volume'
}

@test "behavioral: a boot with no host NTFS mounted is a no-op, not an unmount" {
    make_stubs 0
    m="$BATS_TEST_TMPDIR/m-none"
    printf 'proc /proc proc rw 0 0\n/dev/sda2 /oldroot xfs rw 0 0\n' > "$m"
    run run_umount_hook "$m" ""
    [ "$status" -eq 0 ]
    [ ! -s "$STUBLOG" ]
}
