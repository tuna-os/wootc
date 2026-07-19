#!/usr/bin/env bats
# silence-discriminator.bats — tell "working quietly" from "wedged" (#40).
#
# Serial silence alone is NOT a failure signal. `bootc install` produces no
# serial output for 10+ minutes while extracting layers, so a naive
# time-since-last-write warning fires on every healthy run.
#
# But silence is also exactly what a dead deployer looks like. Two runs this
# session were indistinguishable by silence alone: one had been quiet 13 minutes
# and was perfectly healthy; another looked identical and had been dead for half
# an hour while the harness printed "Deploying..." for 76 more minutes.
#
# Guest CPU is the discriminator, and it is the one signal that has never lied:
#     silence + high CPU (measured 130-170% mid-install) -> working
#     silence + idle CPU                                 -> genuinely wedged
#     silence + NO qemu process                          -> the guest is gone
#
# Getting this wrong in either direction is expensive: crying wolf trains the
# reader to ignore the warning, and staying silent costs a full 90-minute budget.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
}

@test "run-e2e.sh is syntactically valid" {
    run bash -n "$E2E"
    [ "$status" -eq 0 ]
}

@test "silence is measured against the serial file, not a counter" {
    grep -q 'SERIAL_AGE=$(( $(date +%s) - $(stat -c %Y "$PTY"' "$E2E"
}

@test "the silence threshold is generous enough for bootc install" {
    # bootc install is quiet for 10+ minutes. A threshold below that guarantees
    # false alarms on every healthy run.
    local t
    t=$(grep -oE 'WOOTC_E2E_SILENCE_WARN_S:-[0-9]+' "$E2E" | grep -oE '[0-9]+$')
    [ -n "$t" ]
    [ "$t" -ge 600 ]
}

@test "guest CPU is sampled before any wedged verdict" {
    grep -q 'GUEST_CPU=' "$E2E"
    local cpu_line warn_line
    cpu_line=$(grep -n 'GUEST_CPU=\$(' "$E2E" | head -1 | cut -d: -f1)
    warn_line=$(grep -n 'likely WEDGED' "$E2E" | head -1 | cut -d: -f1)
    [ -n "$cpu_line" ] && [ -n "$warn_line" ]
    [ "$cpu_line" -lt "$warn_line" ]
}

@test "high CPU during silence is reported as WORKING, not warned about" {
    # This is the anti-cry-wolf half. Without it the warning fires every run and
    # stops being read.
    grep -q 'working)' "$E2E"
}

@test "low CPU during silence is called out as wedged" {
    grep -q 'likely WEDGED, not slow' "$E2E"
}

@test "a missing QEMU process is distinguished from a slow one" {
    # "guest is gone" and "guest is busy" need opposite responses.
    grep -q 'NO QEMU process' "$E2E"
}

@test "the CPU threshold is a real comparison, not a string test" {
    # pcpu is a float ("85.9"), so [ ] numeric tests fail on it.
    grep -q "awk -v c=\"\$GUEST_CPU\"" "$E2E"
}

@test "the threshold is overridable for slow or busy hosts" {
    grep -q 'WOOTC_E2E_SILENCE_WARN_S' "$E2E"
}
