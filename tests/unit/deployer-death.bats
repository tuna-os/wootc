#!/usr/bin/env bats
# deployer-death.bats — a dead deployer must be detected, not waited out.
#
# WHAT HAPPENED (himachal + the hosted runner, same day):
#
# The deploy actually SUCCEEDED through fisherman —
#   08:03:09 phase: fisherman — this pulls the image and deploys it...
#   08:13:46 phase: verification          <- 10 minutes, image installed
#   08:13:47 Mounted installed system root at /dev/nbd1p3
#   08:13:47   ostree deployment: /ostree/deploy/default/deploy/2f09...
# and then STOPPED. 31 minutes later: "reboot: Restarting system".
#
# The guest came back as Windows. But the harness kept printing "Deploying..."
# for another 76 minutes and finally reported a timeout, because:
#
#   1. DEPLOYER_REBOOT_SEEN only matched the deployer's own "Rebooting" string,
#      not the KERNEL's "reboot: Restarting system"; and
#   2. nothing treated "Windows is answering QGA again" as evidence that the
#      deployer is no longer running.
#
# Manual inspection of the live VM found this in two minutes — `qga powershell
# $env:OS` returned Windows_NT while the harness still believed a Linux deployer
# was mid-install. Ninety-minute blind waits cost far more than they save.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
}

@test "both scripts are syntactically valid" {
    run bash -n "$E2E";    [ "$status" -eq 0 ]
    run bash -n "$DEPLOY"; [ "$status" -eq 0 ]
}

@test "the kernel's reboot message counts as a reboot" {
    grep -q 'reboot: Restarting system' "$E2E"
}

@test "Windows answering QGA without completion is a failure, not a wait" {
    grep -q 'WINDOWS_BACK_STREAK' "$E2E"
    grep -q 'Deployer is gone' "$E2E"
}

@test "the streak resets when Windows is NOT answering" {
    # Otherwise a single probe blip mid-deploy accumulates toward a false abort.
    grep -q 'WINDOWS_BACK_STREAK=0' "$E2E"
}

@test "the failure prints the deployer's own log, not just a verdict" {
    # The persisted log is the whole story once the deployer is gone.
    grep -q 'Last lines of the deployer.s own log' "$E2E"
}

# ── the silent stretch that hid the hang ────────────────────────────────────

@test "the post-fisherman verification stretch is instrumented" {
    # The journal's last line was the /boot mount, and everything after it was
    # silent — so a 31-minute hang could not be localised to a step.
    local n
    n=$(grep -c 'log "  verify:' "$DEPLOY")
    [ "$n" -ge 4 ]
}

@test "the closure self-test cannot hang the deploy" {
    # It EXECUTES a staged binary; a blocked exec there is indistinguishable
    # from a wedged deployer and costs a whole run to tell apart.
    grep -q 'timeout 30 "\$NBD_DIR/\$NBD_LOADER_NAME"' "$DEPLOY"
}

@test "instrumentation brackets the dracut module copy and the closure" {
    grep -q 'verify: copying 99wootc-boot dracut module' "$DEPLOY"
    grep -q 'verify: dracut module copied' "$DEPLOY"
    grep -q 'verify: closure has' "$DEPLOY"
}
