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
    RUNNER="${RUNNER:-$REPO_ROOT/tests/e2e/run-e2e.sh}"
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
    # And the matrix exercises btrfs on an image whose kernel can LOAD it.
    # An EL-family cell (bluefin:lts, yellowfin) can only ever fail here —
    # see the preflight test below and run 30700616717.
    grep -Pq 'smoke\tfedora-gnome-win11pro-btrfs\tghcr.io/tuna-os/bonito:gnome\t.*filesystem=btrfs' "$REPO_ROOT/tests/e2e/matrix.tsv"
    run grep -P '^\S+\t\S*btrfs\S*\t\S*(bluefin:lts|yellowfin)' "$REPO_ROOT/tests/e2e/matrix.tsv"
    [ "$status" -ne 0 ]
}

@test "a btrfs deploy is refused when the target kernel cannot load btrfs" {
    # Knowable at deploy time in seconds; the alternative is a green deploy
    # followed by a Phase-2 emergency shell 25 minutes later
    # (bluefin-lts-win11pro-btrfs, hosted matrix run 30700616717).
    grep -q 'btrfs preflight' "$DEPLOY"
    # The SIGNER is the observable — presence alone says nothing about whether
    # a locked-down kernel will accept the module.
    grep -q 'modinfo -k "\$KV" -F signer btrfs' "$DEPLOY"
    grep -q 'REF_SIGNER' "$DEPLOY"
    # Fail CLOSED on a positive mismatch and on a missing module...
    grep -q 'ships no btrfs module for its kernel' "$DEPLOY"
    grep -q 'out-of-tree module' "$DEPLOY"
    # ...and the refusal must exit, not warn and carry on.
    for msg in 'ships no btrfs module for its kernel' 'out-of-tree module'; do
        fail_line=$(grep -n "$msg" "$DEPLOY" | head -1 | cut -d: -f1)
        exit_line=$(awk -v start="$fail_line" 'NR > start && /^[[:space:]]*exit 1/ { print NR; exit }' "$DEPLOY")
        [ -n "$fail_line" ] && [ -n "$exit_line" ]
        [ "$exit_line" -le $((fail_line + 8)) ]
    done
    # Bounded probe — no unbounded podman in the deployer (house rule).
    grep -q 'BTRFS_PROBE="$(timeout 120 podman run' "$DEPLOY"
    # ...but never fail on an inconclusive probe: an unsigned-module kernel
    # reports an empty signer for both, and refusing there breaks working images.
    grep -q 'btrfs preflight could not inspect' "$DEPLOY"
    grep -q -- '-n "\$BTRFS_SIGNER" && -n "\$REF_SIGNER"' "$DEPLOY"
}

@test "the Phase-2 emergency verdict reads the whole boot, and names the btrfs case" {
    # The attach line lands ~2 minutes before the emergency, so diagnosing
    # from the poll loop's 5-second delta reported "root.disk never attached"
    # against a serial that says it attached cleanly (run 30700616717).
    grep -q 'PHASE2_BYTE0=\$LAST_BYTE' "$RUNNER"
    grep -q 'PHASE2_OUTPUT=\$(tail -c "+\$((PHASE2_BYTE0 + 1))" "\$PTY")' "$RUNNER"
    grep -q 'ATTACHED=\$(printf .\%s\\n. "\$PHASE2_OUTPUT"' "$RUNNER"
    # An unloadable btrfs is its own verdict, not a mount failure.
    grep -q 'module loaded=0|Loading of module with unavailable key is rejected' "$RUNNER"
    grep -q 'the target kernel never loaded btrfs' "$RUNNER"
}

@test "the Phase-2 → Windows reboot requires the guest to actually go down" {
    # A guest-exec RPC accepting `systemctl reboot` only proves a process
    # spawned. On bonito nothing happened: Phase 2 sat at its login prompt
    # while the harness waited 10 minutes for Windows (runs 30700616717 /
    # 30704513401). The harness must watch the Linux agent go silent, force
    # a QEMU reset if it does not, and then assert WINDOWS answered — a
    # Phase 2 that never went down satisfies a bare QGA wait instantly.
    grep -q "systemctl reboot || systemctl reboot -ff" "$RUNNER"
    grep -q 'still answering QGA 45s after the reboot request' "$RUNNER"
    # The forced reset drains the HMP banner first (record-video.sh's proven
    # pattern), never a blind sendall.
    grep -q 's.recv(4096); s.sendall(b"system_reset' "$RUNNER"
    reboot_line=$(grep -n 'Rebooting Phase 2 Linux' "$RUNNER" | head -1 | cut -d: -f1)
    awk -v s="$reboot_line" 'NR>s && NR<s+40' "$RUNNER" | grep -q 'qga_wait_windows 600'
}

@test "ext4 stays the sealed default until #35 is proven green" {
    # btrfs remains reachable via wootc.filesystem=btrfs; flipping the sealed
    # default is an E2E decision (a green btrfs matrix run), not a code one.
    grep -q 'FILESYSTEM=ext4' "$DEPLOY"
    grep -q 'btrfs blocked on #35\|btrfs stays reachable' "$DEPLOY"
}
