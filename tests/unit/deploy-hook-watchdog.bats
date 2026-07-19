#!/usr/bin/env bats
# deploy-hook-watchdog.bats — the watchdog must not outlive the deployer.
#
# ROOT CAUSE of "Phase 2 never boots", found by inspecting a LIVE deployer over
# QGA rather than by another 90-minute run.
#
# deploy-hook.sh started a dead-man watchdog as a fire-and-forget subshell:
#
#     ( sleep 2700; ...force_reboot ) &
#
# Nothing ever killed it. When the deployer returned, dracut-initqueue blocked
# in wait() for that leftover 45-minute sleep. The live process tree was
# unambiguous:
#
#     433  1    S  do_wait            /usr/bin/sh /usr/bin/dracut-initqueue
#     435  433  S  hrtimer_nanosleep  sleep 2700
#
# — no deployer process at all, just the initqueue waiting on the watchdog.
# The box then rebooted at exactly t=2702s when the sleep expired.
#
# The damage went well beyond a slow run:
#   * the deployer's real exit status was NEVER printed, so nobody knew whether
#     the deploy had succeeded or failed;
#   * everything after the deployer — the Phase-2 BLS entry, the 99wootc-boot
#     module, the initramfs regen — never ran, so Phase 2 was not merely broken
#     but UNBOOTABLE (GRUB offered only "Install wootc", no installed system);
#   * the harness blamed a slow deploy and waited out its full 90-minute budget.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HOOK="$REPO_ROOT/payload/deployer/deploy-hook.sh"
}

@test "the hook is syntactically valid" {
    run bash -n "$HOOK"
    [ "$status" -eq 0 ]
}

@test "the watchdog cancels via a FLAG, never a signal" {
    # Two signal-based designs failed live:
    #   kill+wait  -> the wait blocked forever when the kill missed;
    #   setsid     -> put the sleep in its own session, out of reach of both the
    #                 pid kill and the process-GROUP kill. Strictly worse.
    # A flag file needs no pid, no signal, and no wait.
    grep -q 'WOOTC_DONE_FLAG' "$HOOK"
    sed -n '/^cancel_watchdog()/,/^}/p' "$HOOK" | grep -q 'WOOTC_DONE_FLAG'
}

@test "cancel_watchdog sends no signals and does not wait" {
    local body
    body=$(sed -n '/^cancel_watchdog()/,/^}/p' "$HOOK")
    run bash -c "printf '%s' \"\$1\" | grep -qE '(^|[^#])(kill|wait|pkill)'" _ "$body"
    [ "$status" -ne 0 ]
}

@test "the watchdog loop exits on its own when the flag appears" {
    sed -n '/^WOOTC_DONE_FLAG=/,/^WATCHDOG_PID=/p' "$HOOK" | grep -q 'while \[ ! -e "\$WOOTC_DONE_FLAG" \]'
}

@test "setsid is gone from the CODE — it made the sleep unkillable" {
    # Match code only. The word survives in a comment explaining why it was
    # removed, and an earlier version of this test matched that comment — the
    # same "test asserts against its own documentation" trap that has now bitten
    # three times in this repo.
    run grep -nE '^[^#]*setsid' "$HOOK"
    [ "$status" -ne 0 ]
}

@test "the flag is cleared at start so a stale one cannot disarm the watchdog" {
    grep -q 'rm -f "\$WOOTC_DONE_FLAG"' "$HOOK"
}

@test "the watchdog is cancelled as soon as the deployer returns" {
    # Every line after wootc-deploy races the 45-minute sleep until this runs.
    local after
    after=$(sed -n '/wootc-deploy || status=/,/Deployer exited/p' "$HOOK")
    echo "$after" | grep -q 'cancel_watchdog'
}

@test "cancellation happens BEFORE the exit-status report" {
    local cancel_line report_line
    cancel_line=$(grep -n '^cancel_watchdog$' "$HOOK" | head -1 | cut -d: -f1)
    report_line=$(grep -n 'Deployer exited with status' "$HOOK" | head -1 | cut -d: -f1)
    [ -n "$cancel_line" ] && [ -n "$report_line" ]
    [ "$cancel_line" -lt "$report_line" ]
}

@test "the exit status reaches kmsg, not just stdout" {
    # stdout was captured by dracut-initqueue and lost when the run wedged; the
    # exit status is the single most useful fact about a failed deploy.
    grep -q 'Deployer exited with status \$status" > /dev/kmsg' "$HOOK"
}

@test "the watchdog still exists — this is not a removal" {
    # It is a genuine dead-man switch for a hung deployer. The bug was that it
    # was uncancellable, not that it existed.
    grep -q '2700' "$HOOK"
    grep -q 'watchdog: deployer hung for 45m' "$HOOK"
}
