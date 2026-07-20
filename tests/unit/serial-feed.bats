#!/usr/bin/env bats
# serial-feed.bats — a dead serial feed must be loud, never silently stale.
#
# The serial log is the only window into a Phase-2 boot, so a broken feed
# invalidates every check downstream of it. Observed on dilli: the in-container
# source vanished, `podman cp` failed on every poll, and because each caller
# swallowed the failure with `|| true`, the harness kept reading the host-side
# copy from an earlier snapshot. That file sat frozen at 7190 bytes for two
# hours while the deploy loop polled it for markers that could never arrive.
#
# Worse, the "PTY not found" guard passed the whole time: it only checks that
# the file exists, and a stale file from a PREVIOUS run exists just fine. So a
# run could silently analyse another run's serial output.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
}

@test "run-e2e.sh is syntactically valid" {
    run bash -n "$E2E"
    [ "$status" -eq 0 ]
}

@test "snapshot_serial reports failure rather than swallowing it" {
    # The old body was a single `cp ... >/dev/null 2>&1` with no branch.
    run grep -A3 '^snapshot_serial()' "$E2E"
    [ "$status" -eq 0 ]
    [[ "$output" == *"if \$DOCKER cp"* ]]
}

@test "a sustained dead feed produces a warning" {
    grep -q 'serial feed is DEAD' "$E2E"
}

@test "the dead-feed warning states that downstream checks are untrustworthy" {
    # Without this, an operator sees a warning and keeps reading the summary.
    grep -q 'cannot be trusted' "$E2E"
}

@test "consecutive failures are counted, and success resets the counter" {
    grep -q 'SERIAL_FAIL_COUNT=$((SERIAL_FAIL_COUNT + 1))' "$E2E"
    grep -q 'SERIAL_FAIL_COUNT=0' "$E2E"
}

@test "the warning fires once, not on every poll" {
    # A per-poll warning at a 5s cadence buries the rest of the log.
    grep -q 'SERIAL_WARNED=true' "$E2E"
    grep -q 'SERIAL_WARNED" = false' "$E2E"
}

@test "a stale PTY from a previous run is deleted before monitoring begins" {
    # The -f guard cannot distinguish this run's serial from the last run's.
    local rm_line guard_line
    rm_line=$(grep -n '^rm -f "\$PTY"' "$E2E" | head -1 | cut -d: -f1)
    guard_line=$(grep -n 'QEMU PTY not found' "$E2E" | head -1 | cut -d: -f1)
    [ -n "$rm_line" ]
    [ -n "$guard_line" ]
    [ "$rm_line" -lt "$guard_line" ]
}

@test "the PTY-missing failure names the source it could not read" {
    # "QEMU PTY not found at <path>" alone sent debugging to the host path,
    # when the actual problem is the container-side feed.
    grep -q 'no serial feed from' "$E2E"
}
