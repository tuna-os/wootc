#!/usr/bin/env bats
# deploy-hook-watchdog.bats — there must be NO background job in this hook.
#
# The in-guest watchdog was removed after causing three regressions and never
# once doing its job. The shape of the bug is structural: ANY background job in
# deploy-hook.sh is a child of dracut-initqueue, and dracut-initqueue waits for
# its children — so a watchdog here blocks the very thing it protects.
#
# Four designs, all observed failing live:
#   1. `( sleep 2700; force_reboot ) &`  -> initqueue blocked 45 min after the
#      deployer returned; Phase-2 setup never ran, exit status never printed;
#   2. + kill/wait  -> the wait blocked FOREVER when the kill missed;
#   3. + setsid     -> put the sleep beyond both pid and process-group kill;
#   4. self-cancelling flag-file loop -> cancellation worked, but the subshell is
#      still a child, so initqueue still blocked:
#        454   1   S  do_wait            /usr/bin/sh /usr/bin/dracut-initqueue
#        7365 454   S  hrtimer_nanosleep  sleep 10
#
# The host covers every case it was for: a wall-clock deploy budget, "Windows
# QGA answering again -> deployer is gone", the kernel reboot recorded but not
# treated as success, and serial silence cross-checked against guest CPU (#40).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HOOK="$REPO_ROOT/payload/deployer/deploy-hook.sh"
}

@test "the hook is syntactically valid" {
    run bash -n "$HOOK"
    [ "$status" -eq 0 ]
}

@test "the hook starts NO background job" {
    # Anything backgrounded here becomes a child of dracut-initqueue, which
    # waits for its children. That is the whole bug class.
    run grep -nE "^[^#]*\) *&\s*$|^[^#]*&\s*$" "$HOOK"
    [ "$status" -ne 0 ]
}

@test "no sleep-based watchdog remains in the code" {
    run grep -nE "^[^#]*sleep 2700" "$HOOK"
    [ "$status" -ne 0 ]
}

@test "no cancel_watchdog / WATCHDOG_PID machinery remains" {
    run grep -nE "^[^#]*(cancel_watchdog|WATCHDOG_PID)" "$HOOK"
    [ "$status" -ne 0 ]
}

@test "the deployer exit status is still reported to kmsg" {
    # With no watchdog this is the ONLY in-guest signal of how the deploy ended.
    grep -q 'Deployer exited with status \$status' "$HOOK"
    grep -q 'Deployer exited with status \$status" > /dev/kmsg' "$HOOK"
}

@test "the failure path still reboots back to Windows" {
    # So QGA-based diagnostics work again after a failed deploy.
    grep -q 'rebooting to Windows in 30s' "$HOOK"
    grep -q 'force_reboot' "$HOOK"
}

@test "the removal is documented so it is not reintroduced" {
    grep -q 'NO in-guest watchdog' "$HOOK"
}
