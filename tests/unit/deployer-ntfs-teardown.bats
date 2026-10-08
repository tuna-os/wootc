#!/usr/bin/env bats
# The deployer must hand the Windows volume back UNMOUNTED, not lazily
# detached (#218, defect #209).
#
# Run 32556250889, bluefin-dakota-win11pro: the deploy passed verify, then
#
#     warning: unmounting /mnt/fisherman-target/.fisherman-scratch:
#         umount -Rl /mnt/fisherman-target/.fisherman-scratch: exit status 1
#     [WARN] /mnt/ntfs still busy after retries; lazy-detaching ...
#     reboot: Restarting system
#     BdsDxe: starting Boot0003 "Windows Boot Manager"
#
# and then 78 minutes of busy CPU with no serial and no Windows QGA. The issue
# was filed as a Phase-2 hang, but Phase 2 was never scheduled: the harness
# was still waiting for Windows to return after the deploy.
#
# The final teardown called `losetup -d` on every NTFS-backed loop. On a loop
# that is still mounted, that only sets autoclear, so root.disk stays open on
# /mnt/ntfs, the umount fails busy, and ntfs3 goes into `reboot -ff` mounted
# rw and dirty. fisherman's leftover target lives at /mnt/fisherman-target,
# outside /mnt/ntfs, so nothing in the teardown ever unmounted it.
#
# These tests run the REAL teardown block from deploy.sh against a fake
# /proc/mounts and record what it does.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    RUNNER="$REPO_ROOT/tests/e2e/run-e2e.sh"
    WORK="$(mktemp -d)"
    export CALLS="$WORK/calls" MOUNTS="$WORK/mounts" LOOPS="$WORK/loops"
    : > "$CALLS"

    # The block between the first sync of the NTFS teardown and the reboot.
    awk '/^# Robustly unmount the host NTFS/ {on=1}
         on && /^sleep 3$/ {exit}
         on {print}' "$DEPLOY" \
        | sed "s#/proc/mounts#$MOUNTS#g" > "$WORK/teardown.sh"
    [ -s "$WORK/teardown.sh" ]

    mkdir -p "$WORK/bin"
    # Stubs record each call. A loop is "busy" while any mount in $MOUNTS is
    # sourced from it; `losetup -d` on a busy loop leaves it attached, as the
    # kernel does (autoclear). umount removes the matching mount lines.
    cat > "$WORK/bin/umount" <<'EOF'
#!/bin/bash
echo "umount $*" >> "$CALLS"
target="${*: -1}"
recursive=false
for a in "$@"; do case "$a" in -R|-Rl|-lR) recursive=true ;; esac; done
if [ "$target" = /mnt/ntfs ]; then
    # Busy while a loop backed by a /mnt/ntfs file is still attached.
    grep -q '/mnt/ntfs/' "$LOOPS" 2>/dev/null && exit 32
fi
if $recursive; then
    awk -v t="$target" '$2 != t && index($2, t "/") != 1' "$MOUNTS" > "$MOUNTS.new"
else
    awk -v t="$target" '$2 != t' "$MOUNTS" > "$MOUNTS.new"
fi
mv "$MOUNTS.new" "$MOUNTS"
EOF
    cat > "$WORK/bin/losetup" <<'EOF'
#!/bin/bash
echo "losetup $*" >> "$CALLS"
case "$1" in
    -ln) cat "$LOOPS" ;;
    -d)
        lp="$2"
        if awk -v lp="$lp" '$1 == lp || index($1, lp "p") == 1 {f=1} END {exit !f}' "$MOUNTS"; then
            exit 0   # busy: autoclear only, still attached
        fi
        awk -v lp="$lp" '$1 != lp' "$LOOPS" > "$LOOPS.new"; mv "$LOOPS.new" "$LOOPS"
        ;;
esac
EOF
    printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/sync"
    printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/sleep"
    chmod +x "$WORK/bin/"*
}

teardown() {
    rm -rf "$WORK"
}

run_teardown() {
    PATH="$WORK/bin:$PATH" bash -c '
        err() { printf "%s\n" "$*" >&2; }
        . "$1"
        echo "ntfs_umounted=$_ntfs_umounted"
    ' _ "$WORK/teardown.sh"
}

@test "teardown block was extracted and is valid bash" {
    run bash -n "$WORK/teardown.sh"
    [ "$status" -eq 0 ]
    grep -q 'losetup -d' "$WORK/teardown.sh"
}

@test "a loop still mounted by fisherman's leftover target is unmounted before detach (#218)" {
    # The run-32556250889 shape: fisherman's target on a partition of the
    # root.disk loop, its scratch mount nested inside, all outside /mnt/ntfs.
    cat > "$LOOPS" <<'EOF'
/dev/loop0 /mnt/ntfs/wootc/disks/root.disk
EOF
    cat > "$MOUNTS" <<'EOF'
/dev/sda3 /mnt/ntfs ntfs3 rw 0 0
/dev/loop0p3 /mnt/fisherman-target btrfs rw 0 0
/dev/loop0p2 /mnt/fisherman-target/boot ext4 rw 0 0
tmpfs /mnt/fisherman-target/.fisherman-scratch tmpfs rw 0 0
EOF
    run run_teardown
    [ "$status" -eq 0 ]
    echo "$output"
    cat "$CALLS"
    # The volume came off cleanly: no lazy detach, no dirty NTFS for Windows.
    [[ "$output" == *"ntfs_umounted=true"* ]]
    [[ "$output" != *"lazy-detaching"* ]]
    ! grep -q '^umount -l /mnt/ntfs$' "$CALLS"
    # Order matters: the holder goes BEFORE the loop is detached.
    first_umount=$(grep -n '^umount -R /mnt/fisherman-target$' "$CALLS" | head -1 | cut -d: -f1)
    detach=$(grep -n '^losetup -d /dev/loop0$' "$CALLS" | head -1 | cut -d: -f1)
    [ -n "$first_umount" ] && [ -n "$detach" ]
    [ "$first_umount" -lt "$detach" ]
    # Deepest first: the nested boot partition before its parent.
    boot=$(grep -n '^umount -R /mnt/fisherman-target/boot$' "$CALLS" | cut -d: -f1)
    [ "$boot" -lt "$first_umount" ]
}

@test "a holder that will not let go is named on the serial before the lazy detach" {
    cat > "$LOOPS" <<'EOF'
/dev/loop0 /mnt/ntfs/wootc/disks/root.disk
EOF
    cat > "$MOUNTS" <<'EOF'
/dev/sda3 /mnt/ntfs ntfs3 rw 0 0
EOF
    # A loop with no mount at all but still attached (an open fd elsewhere):
    # losetup -d cannot clear it in this stub because we re-add it.
    cat > "$WORK/bin/losetup" <<'EOF'
#!/bin/bash
echo "losetup $*" >> "$CALLS"
[ "$1" = -ln ] && cat "$LOOPS"
exit 0
EOF
    chmod +x "$WORK/bin/losetup"
    run run_teardown
    [ "$status" -eq 0 ]
    [[ "$output" == *"lazy-detaching"* ]]
    [[ "$output" == *"holder: loop /dev/loop0 /mnt/ntfs/wootc/disks/root.disk"* ]]
    [[ "$output" == *"holder: mount /dev/sda3 on /mnt/ntfs (ntfs3)"* ]]
    grep -q '^umount -l /mnt/ntfs$' "$CALLS"
    # run-e2e.sh stops on fatal|panic|[FAIL] in the deployer serial. This
    # path runs AFTER a passed verify, so it may only ever WARN.
    ! echo "$output" | grep -qE 'fatal|panic|\[FAIL\]'
}

@test "harness names a hung Windows return as such, not as a deploy timeout" {
    # #209/#218 was triaged as a Phase-2 hang because the timeout branch said
    # "Deployment did not complete" for a deploy that had finished.
    block=$(awk '/^\[ "\$DEPLOY_COMPLETE" = true \] \|\| \{/ {on=1} on {print} on && /^}$/ {exit}' "$RUNNER")
    [ -n "$block" ]
    echo "$block" | grep -q 'elif \[ "\$DEPLOYER_REBOOT_SEEN" = true \]'
    echo "$block" | grep -q 'Windows never came back'
    echo "$block" | grep -q 'Phase 2 was never scheduled'
    # The reboot branch must come before the generic timeout message.
    reboot_line=$(echo "$block" | grep -n 'DEPLOYER_REBOOT_SEEN' | head -1 | cut -d: -f1)
    generic_line=$(echo "$block" | grep -n 'Deployment did not complete' | cut -d: -f1)
    [ "$reboot_line" -lt "$generic_line" ]
}
