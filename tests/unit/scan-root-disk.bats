#!/usr/bin/env bats
# scan-root-disk.bats — the deployer must find root.vhdx on a freshly-made volume.
#
# THE BITLOCKER FAILURE (#36, reproduced twice):
#
#   [wootc] Could not find /wootc/disks/root.vhdx on any partition
#
# while the volume holding it was present the whole time. On the BitLocker path
# setup-wootc.ps1 never decrypts C: — it shrinks it, creates a fresh unencrypted
# NTFS volume for Linux, and reboots almost immediately. That volume still
# carries the NTFS dirty bit, and ntfs3 REFUSES a dirty volume even read-only.
# The scan's `mount ... 2>/dev/null` swallowed the failure, the partition was
# skipped in silence, and the deployer blamed the file for being absent.
#
# Two properties are pinned here: try harder before giving up, and never skip a
# device without saying why.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
}

@test "deploy.sh is syntactically valid" {
    run bash -n "$DEPLOY"
    [ "$status" -eq 0 ]
}

@test "a dirty NTFS volume is still mountable via ntfs3 -o force" {
    # The whole point: a just-formatted, not-cleanly-unmounted volume.
    grep -q 'mount -t ntfs3 -o ro,force' "$DEPLOY"
}

@test "the plain read-only mount is still tried first" {
    # force is a fallback, not the default — a clean volume should mount clean.
    local body
    body=$(sed -n '/^try_mount_scan()/,/^}/p' "$DEPLOY")
    local plain force
    plain=$(echo "$body" | grep -n 'mount -t ntfs3 -o ro "' | head -1 | cut -d: -f1)
    force=$(echo "$body" | grep -n 'ro,force' | head -1 | cut -d: -f1)
    [ -n "$plain" ] && [ -n "$force" ]
    [ "$plain" -lt "$force" ]
}

@test "ntfs-3g is the last resort when the kernel driver is absent" {
    sed -n '/^try_mount_scan()/,/^}/p' "$DEPLOY" | grep -q 'ntfs-3g -o ro'
}

@test "an unmountable device is logged, never skipped silently" {
    # Silent skipping is what made #36 unattributable across two full runs.
    grep -q 'not mountable as NTFS' "$DEPLOY"
}

@test "a mounted device without the vhdx is also logged" {
    # Distinguishes "could not read this volume" from "read it, file not there"
    # — different bugs, different fixes.
    grep -q 'no \${ROOT_DISK_PATH}' "$DEPLOY"
}

@test "success reports which driver worked" {
    # Tells us whether images need ntfs-3g at all, and whether force was needed
    # — i.e. whether the dirty-bit theory is what actually fired.
    grep -q 'mounted via \${drv}' "$DEPLOY"
}

@test "the scan still fails closed when nothing carries the vhdx" {
    local body
    body=$(sed -n '/^scan_for_root_disk()/,/^    return 1/p' "$DEPLOY")
    echo "$body" | grep -q 'return 1'
}
