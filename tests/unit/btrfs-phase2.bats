#!/usr/bin/env bats
# btrfs sealed root, Phase 2 (#35): the deploy formats and completes, the
# attach is clean (loop partitions + by-uuid symlinks at t=3s), and
# sysroot.mount STILL times out — because a by-uuid symlink is not device
# readiness. udev's 64-btrfs.rules gates btrfs partitions behind
# IMPORT{builtin}="btrfs ready" (SYSTEMD_READY=0 until the btrfs module has
# the device registered), so the root=UUID device UNIT never activates if
# btrfs.ko is not loaded when the attach's partition events land.
#
# The fix is layered, and constrained by the no-modprobe lesson
# (tests/unit/raw-loopback.bats: a hook modprobe under Secure Boot lockdown
# is rejected and blocks the correctly-signed module):
#   1. deploy.sh bakes a modules-load.d entry into the regenerated Phase-2
#      initramfs for btrfs deploys — systemd-modules-load loads btrfs.ko
#      early, dependency-resolved, long before wootc-attach.service;
#   2. the attach hook registers the just-attached partitions (btrfs device
#      scan) and re-triggers CHANGE events so the readiness import re-runs;
#   3. the hook reports module-loaded + SYSTEMD_READY per btrfs partition,
#      so a persisting #35 is diagnosable from one serial log.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="${DEPLOY:-$REPO_ROOT/payload/deployer/deploy.sh}"
    HOOK="${HOOK:-$REPO_ROOT/platform/dracut/99wootc-boot/wootc-attach-loop.sh}"
    MODSETUP="${MODSETUP:-$REPO_ROOT/platform/dracut/99wootc-boot/module-setup.sh}"
}

@test "btrfs deploys bake an early modules-load.d entry into the Phase-2 initramfs" {
    grep -q 'FILESYSTEM" == btrfs' "$DEPLOY"
    grep -q 'modules-load.d/wootc-btrfs.conf' "$DEPLOY"
    # The include dir must be created under $DEPLOY_ROOT — dracut runs
    # chrooted, so a path on the deployer's own / is invisible to it.
    grep -q '"\$DEPLOY_ROOT/run/wootc-btrfs-inc' "$DEPLOY"
    grep -q -- '--include /run/wootc-btrfs-inc /' "$DEPLOY"
    # And the args must actually reach the regen invocation.
    grep -q '"\${DRACUT_INCLUDE_ARGS\[@\]}"' "$DEPLOY"
}

@test "the attach hook clears the btrfs udev readiness gate without modprobe" {
    grep -q 'TYPE="btrfs"' "$HOOK"
    grep -q 'btrfs device scan' "$HOOK"
    grep -q -- '--action=change' "$HOOK"
    # Diagnosability: one serial line must discriminate "module never loaded"
    # from "device never became ready" from "different bug entirely".
    grep -q 'SYSTEMD_READY' "$HOOK"
    grep -q '/proc/modules' "$HOOK"
    # The no-modprobe constraint stays intact (also asserted by
    # raw-loopback.bats; repeated here so THIS file fails too if the btrfs
    # block regresses into a modprobe).
    run grep -nE '^[^#]*modprobe ' "$HOOK"
    [ "$status" -ne 0 ]
}

@test "the dracut module carries btrfs.ko and (optionally) btrfs-progs" {
    # dracut's own 90btrfs is only auto-selected when the image ships
    # btrfs-progs; wootc must not depend on that.
    grep -q 'instmods btrfs' "$MODSETUP"
    grep -q 'inst_multiple -o btrfs' "$MODSETUP"
}

@test "the filesystem axis reaches the deployer from every harness layer" {
    # WOOTC_E2E_FILESYSTEM → wootc-config.txt → run-wootc-e2e.ps1 →
    # setup-wootc.ps1 → wootc.filesystem= karg. A break in any hop silently
    # runs the btrfs cell on the default filesystem and calls it green.
    grep -q 'WOOTC_E2E_FILESYSTEM' "$REPO_ROOT/tests/e2e/run-e2e.sh"
    grep -q "printf 'Filesystem=%s" "$REPO_ROOT/tests/e2e/run-e2e.sh"
    grep -q '\$setupArgs.Filesystem = \$cfg.Filesystem' "$REPO_ROOT/tests/e2e/oem/run-wootc-e2e.ps1"
    grep -q 'wootc.filesystem=\$Filesystem' "$REPO_ROOT/tests/e2e/setup-wootc.ps1"
    grep -q '\[ValidateSet("xfs", "ext4", "btrfs", "auto")\]' "$REPO_ROOT/tests/e2e/setup-wootc.ps1"
    # Workflow plumbing: the reusable job takes it, the matrix passes it.
    grep -q 'WOOTC_E2E_FILESYSTEM: \${{ inputs.filesystem }}' "$REPO_ROOT/.github/workflows/e2e-hosted.yml"
    grep -q 'filesystem: \${{ matrix.filesystem }}' "$REPO_ROOT/.github/workflows/e2e-matrix.yml"
    # And the matrix actually exercises btrfs on the proven baseline.
    grep -Pq 'smoke\tbluefin-lts-win11pro-btrfs\t.*filesystem=btrfs' "$REPO_ROOT/tests/e2e/matrix.tsv"
}

@test "ext4 stays the sealed default until #35 is proven green" {
    # btrfs remains reachable via wootc.filesystem=btrfs; flipping the sealed
    # default is an E2E decision (a green btrfs matrix run), not a code one.
    grep -q 'FILESYSTEM=ext4' "$DEPLOY"
    grep -q 'btrfs blocked on #35\|btrfs stays reachable' "$DEPLOY"
}
