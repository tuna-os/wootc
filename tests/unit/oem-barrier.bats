#!/usr/bin/env bats
# oem-barrier.bats — the OEM barrier must prove the marker is from THIS run.
#
# The barrier used to accept any readable C:\OEM\e2e-setup-complete.txt. A
# marker left behind by a previous run satisfied it instantly, so the harness
# jumped straight to "monitoring the deployer" while Windows setup was still
# staging the payload and the BCD one-shot. The VM then rebooted into Windows —
# serial ending at
#     BdsDxe: starting Boot0003 "Windows Boot Manager" ... bootmgfw.efi
# with zero [wootc] phase: lines — and the harness burned its full budget
# watching a VM that was never deploying. Observed on two runners, identically.
#
# It went unnoticed for a long time because snapshot_before_deployer() used to
# spend 10-20 minutes on an fsfreeze + 28 GiB copy at exactly this point, which
# incidentally gave OEM setup the time it needed. The snapshot was accidentally
# LOAD-BEARING as a sleep, and disabling it exposed the race.
#
# The fix is a real check, not a delay: the guest stamps the run id into the
# marker and the barrier requires it to match.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
    PS1="$REPO_ROOT/tests/e2e/oem/run-wootc-e2e.ps1"
}

@test "run-e2e.sh is syntactically valid" {
    run bash -n "$E2E"
    [ "$status" -eq 0 ]
}

@test "the run id is passed to the guest via wootc-config.txt" {
    grep -q "printf 'RunId=%s" "$E2E"
}

@test "the guest stamps the run id into the completion marker, not a constant" {
    grep -q 'Set-Content -Path $completePath' "$PS1"
    grep -q '\$runId | Set-Content -Path \$completePath' "$PS1"
    # the old constant must be gone
    run grep -n '"ok" | Set-Content -Path \$completePath' "$PS1"
    [ "$status" -ne 0 ]
}

@test "the guest falls back safely when RunId is absent from the config" {
    # An older config must not crash setup; it should write something that
    # simply will not match, so the barrier waits and then reports STALE.
    grep -q 'if ($cfg.ContainsKey("RunId"))' "$PS1"
    grep -q '"unknown"' "$PS1"
}

@test "the barrier requires the marker to equal this run's id" {
    grep -q 'BARRIER_MARK' "$E2E"
    grep -q '\[ "\$BARRIER_MARK" = "\$RUN_ID" \]' "$E2E"
}

@test "an empty marker does NOT satisfy the barrier" {
    # `qga_read ... >/dev/null 2>&1` passing on an empty-but-readable file is
    # exactly how this got through before.
    grep -q '\[ -n "\$BARRIER_MARK" \]' "$E2E"
}

@test "the barrier no longer passes on a bare readable-file check" {
    run grep -n "if qga_read 'C:.OEM.e2e-setup-complete.txt' >/dev/null 2>&1; then" "$E2E"
    [ "$status" -ne 0 ]
}

@test "a barrier timeout distinguishes 'never completed' from 'stale marker'" {
    # Two very different fixes: one means OEM setup failed, the other means the
    # guest's C:\OEM is from an earlier run. Guessing costs a VM session.
    grep -q 'marker absent: OEM setup never completed' "$E2E"
    grep -q 'STALE marker' "$E2E"
}
