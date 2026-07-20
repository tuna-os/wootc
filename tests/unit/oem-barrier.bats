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

@test "the OEM sync uses the CONTAINER's view of the mount, not a host path" {
    # qga.py runs INSIDE the container, so a host path silently fails every
    # write and the guest quietly keeps its stale copies. My first attempt used
    # $OEM_DIR and every file reported "could not refresh".
    sed -n '/^qga_sync_oem()/,/^}/p' "$E2E" | grep -q 'qga_call write "/oem/'
    run grep -n 'qga_call write "\$OEM_DIR' "$E2E"
    [ "$status" -ne 0 ]
}

@test "C:\\OEM is refreshed from the host before setup starts" {
    # C:\OEM comes from the ISO at install time, so a REUSED Windows carries
    # whatever run-wootc-e2e.ps1 / wootc-config.txt existed when that image was
    # built. With the RunId barrier that deadlocks: the old script stamps a
    # constant, the host never matches it and so never writes the snapshot
    # marker, and the guest dies on its own 10-minute deadline —
    #   "Timed out waiting for the host to snapshot the Windows installation"
    # Both sides waiting on each other.
    grep -q 'qga_sync_oem' "$E2E"
}

@test "the OEM sync is unconditional, not limited to --skip-install" {
    # A stale C:\OEM deadlocks the RunId barrier whenever Windows was installed
    # by an earlier run — that is not exclusive to the reuse flag.
    local block
    block=$(sed -n '/if \[ "\$SKIP_INSTALL" = true \]/,/^fi$/p' "$E2E")
    echo "$block" | grep -q 'qga_sync_oem' && return 1
    return 0
}

@test "the refresh happens BEFORE the OEM script is launched" {
    local refresh_line launch_line
    refresh_line=$(grep -n '^qga_sync_oem$' "$E2E" | head -1 | cut -d: -f1)
    launch_line=$(grep -n 'Start-Process -FilePath' "$E2E" | head -1 | cut -d: -f1)
    [ -n "$refresh_line" ]
    [ -n "$launch_line" ]
    [ "$refresh_line" -lt "$launch_line" ]
}

@test "a barrier timeout distinguishes 'never completed' from 'stale marker'" {
    # Two very different fixes: one means OEM setup failed, the other means the
    # guest's C:\OEM is from an earlier run. Guessing costs a VM session.
    grep -q 'marker absent: OEM setup never completed' "$E2E"
    grep -q 'STALE marker' "$E2E"
}
