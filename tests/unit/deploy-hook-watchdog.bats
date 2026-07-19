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

@test "the watchdog pid is captured" {
    # A fire-and-forget subshell cannot be cancelled.
    grep -q 'WATCHDOG_PID=\$!' "$HOOK"
}

@test "cancel_watchdog NEVER waits on the watchdog" {
    # A bare `wait $pid` blocks forever when the kill does not take — which is
    # exactly what happened: the deploy had exited and unmounted, yet
    # `sleep 2700` survived and dracut-initqueue sat in do_wait indefinitely.
    # That traded a 45-minute block for a permanent one.
    local body
    body=$(sed -n '/^cancel_watchdog()/,/^}/p' "$HOOK")
    [ -n "$body" ]
    run bash -c "printf '%s' \"\$1\" | grep -qE '^[^#]*wait +\"?\\\$WATCHDOG_PID'" _ "$body"
    [ "$status" -ne 0 ]
}

@test "cancel_watchdog escalates TERM -> KILL and kills the process group" {
    # The subshell may fork the sleep, so killing only $! can leave it running.
    local body
    body=$(sed -n '/^cancel_watchdog()/,/^}/p' "$HOOK")
    echo "$body" | grep -q 'kill -TERM "\$WATCHDOG_PID"'
    echo "$body" | grep -q 'kill -KILL "\$WATCHDOG_PID"'
    echo "$body" | grep -q 'kill -TERM -"\$WATCHDOG_PID"'
}

@test "a stray watchdog sleep is swept as a last resort" {
    sed -n '/^cancel_watchdog()/,/^}/p' "$HOOK" | grep -q "pkill -KILL -f"
}

@test "the watchdog is disowned so nothing waits on it at exit" {
    sed -n '/^cancel_watchdog()/,/^}/p' "$HOOK" | grep -q 'disown'
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
    grep -q 'sleep 2700' "$HOOK"
    grep -q 'watchdog: deployer hung for 45m' "$HOOK"
}
