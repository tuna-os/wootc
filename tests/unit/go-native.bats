#!/usr/bin/env bats
# go-native.bats — data-safety invariants for wootc-go-native (Phase 3).
#
# A bug here repartitions a real disk, so these tests pin the guards that must
# NEVER silently regress. All black-box: the script is invoked as a subprocess
# with its baked-in WOOTC_GN_* fixture hooks — no VM, no real disks, no edits
# to the script. The destructive paths are proven inert with PATH stubs: every
# tool that could touch a disk (bootc, podman, sfdisk, ntfsresize, mkfs.xfs,
# efibootmgr, mount) is replaced by a stub that records "I was called" into a
# marker file. Asserting the marker is ABSENT proves no disk was touched — a
# stronger claim than merely asserting the plan text printed.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    GN="$REPO_ROOT/payload/migration/wootc-go-native"
    TMP="$BATS_TEST_TMPDIR"

    # PATH stub jail: any disk-touching tool writes to $CALLED and exits 0.
    STUBDIR="$TMP/stubs"; mkdir -p "$STUBDIR"
    CALLED="$TMP/called"
    for tool in bootc podman sfdisk ntfsresize mkfs.xfs efibootmgr mount umount \
                growpart xfs_growfs bootupctl rsync; do
        cat >"$STUBDIR/$tool" <<STUB
#!/bin/bash
echo "$tool \$*" >>"$CALLED"
exit 0
STUB
        chmod +x "$STUBDIR/$tool"
    done
    export PATH="$STUBDIR:$PATH"

    # Default fixtures: on loopback, no host conf, empty home (no converted dirs).
    export WOOTC_GN_HOSTCONF="$TMP/nonexistent.conf"
    export WOOTC_GN_HOME="$TMP/home"; mkdir -p "$WOOTC_GN_HOME/.config/wootc"
}

# assert the disk-touching stubs were never invoked.
refute_disk_touched() {
    if [[ -e "$CALLED" ]]; then
        echo "expected NO disk tool call, but got:"; cat "$CALLED"
        return 1
    fi
}

# ── plan / check are always safe ────────────────────────────────────────────

@test "plan on loopback describes the graduate stages and touches nothing" {
    WOOTC_GN_FORCE_LOOP=1 run bash "$GN" plan
    [ "$status" -eq 0 ]
    [[ "$output" == *"Still on Windows NTFS  : yes"* ]]
    [[ "$output" == *"Graduate root to native"* ]]
    [[ "$output" == *"Remove Windows"* ]]
    refute_disk_touched
}

@test "plan when already native says nothing to graduate" {
    WOOTC_GN_FORCE_LOOP=0 WOOTC_GN_ROOT_SRC=/dev/sda3 run bash "$GN" plan
    [ "$status" -eq 0 ]
    [[ "$output" == *"already runs from a native Linux partition"* ]]
    refute_disk_touched
}

@test "check reports loopback + counts converted folders, never touches disk" {
    touch "$WOOTC_GN_HOME/.config/wootc/converted-Documents"
    touch "$WOOTC_GN_HOME/.config/wootc/converted-Pictures"
    WOOTC_GN_FORCE_LOOP=1 run bash "$GN" check
    [[ "$output" == *"loopback"* ]]
    [[ "$output" == *"2 user folder(s) already native"* ]]
    refute_disk_touched
}

# ── the safety gates: these must REFUSE (non-zero, no disk touched) ──────────

@test "migrate --reclaim REFUSES while still on loopback" {
    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 \
        run bash "$GN" migrate --reclaim --execute
    [ "$status" -ne 0 ]
    [[ "$output" == *"still running from root.disk"* ]]
    refute_disk_touched
}

@test "migrate --reclaim REFUSES when no folders are verified native" {
    # native now, but zero converted-* markers → data may still be Windows-only
    WOOTC_GN_FORCE_LOOP=0 WOOTC_GN_ROOT_SRC=/dev/sda3 \
        WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 \
        run bash "$GN" migrate --reclaim --execute
    [ "$status" -ne 0 ]
    [[ "$output" == *"no folders verified native"* ]]
    refute_disk_touched
}

@test "migrate --execute REFUSES without WOOTC_GN_ALLOW_DESTRUCTIVE=1" {
    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 \
        run bash "$GN" migrate --dual-boot --execute
    [ "$status" -ne 0 ]
    [[ "$output" == *"WOOTC_GN_ALLOW_DESTRUCTIVE=1"* ]]
    refute_disk_touched
}

@test "migrate with no mode REFUSES" {
    run bash "$GN" migrate
    [ "$status" -ne 0 ]
    [[ "$output" == *"choose --dual-boot"* ]]
    refute_disk_touched
}

# ── dry-run: prints the plan but must touch NOTHING ─────────────────────────

@test "migrate --dual-boot (no --execute) is a dry run that touches no disk" {
    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 WOOTC_GN_ESP=/dev/sda1 \
        run bash "$GN" migrate --dual-boot
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY RUN"* ]]
    [[ "$output" == *"Re-run with --execute"* ]]
    refute_disk_touched
}

@test "migrate --reclaim dry run (native + converted) prints IRREVERSIBLE plan, no disk touched" {
    touch "$WOOTC_GN_HOME/.config/wootc/converted-Documents"
    WOOTC_GN_FORCE_LOOP=0 WOOTC_GN_ROOT_SRC=/dev/sda3 \
        WOOTC_GN_DISK=/dev/sda WOOTC_GN_NTFS=/dev/sda2 \
        run bash "$GN" migrate --reclaim
    [ "$status" -eq 0 ]
    [[ "$output" == *"IRREVERSIBLE"* ]]
    refute_disk_touched
}

# ── layout discovery failure is a clean refusal, not a crash ────────────────

@test "migrate REFUSES when the Windows disk cannot be located" {
    # no host conf, no WOOTC_GN_DISK/NTFS → discover_layout fails
    WOOTC_GN_FORCE_LOOP=1 run bash "$GN" migrate --dual-boot
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not locate the Windows disk"* ]]
    refute_disk_touched
}

# ── to-disk guard: never install onto the Windows disk itself ───────────────
# graduate_to_disk_execute checks `-b $target` before `target != $DISK`, so the
# target must be a real block device to reach the guard. Use a loop device.

@test "migrate --to-disk REFUSES to install onto the Windows disk" {
    if [[ $EUID -ne 0 ]] && ! command -v sudo >/dev/null; then
        skip "needs root/sudo for losetup"
    fi
    local img="$TMP/win.img" loopdev
    truncate -s 16M "$img"
    loopdev=$(losetup --show -f "$img" 2>/dev/null) || sudo losetup --show -f "$img" 2>/dev/null || skip "losetup unavailable"
    [ -n "$loopdev" ] || skip "no loop device"

    WOOTC_GN_FORCE_LOOP=1 WOOTC_GN_DISK="$loopdev" WOOTC_GN_NTFS="${loopdev}p2" WOOTC_GN_ESP="${loopdev}p1" \
    WOOTC_GN_ALLOW_DESTRUCTIVE=1 \
        run bash "$GN" migrate --to-disk "$loopdev" --execute

    losetup -d "$loopdev" 2>/dev/null || sudo losetup -d "$loopdev" 2>/dev/null || true
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to install onto the Windows disk"* ]]
    refute_disk_touched
}
