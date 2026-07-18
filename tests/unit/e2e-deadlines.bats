#!/usr/bin/env bats
# e2e-deadlines.bats — wait loops must be bound by wall-clock, not a tick count.
#
# Every wait loop in the E2E harness used to track time by incrementing a
# counter next to `sleep 5`. That counter is not wall-clock: blocking calls in
# the loop body (qga_read, qga_windows_probe, snapshot_serial) burn real time
# without advancing it. Measured against a real stalled run, the counter
# advanced at 0.68x wall, so:
#
#   * the nominal 45-minute deploy timeout was really ~66 minutes;
#   * "Deploying... (49m)" was printed at 72 real minutes;
#   * an operator watching the log could not tell "slow but within budget" from
#     "wedged", and the run looked hung when it was not.
#
# The fix is deadline_in/past_deadline against `date +%s`. These tests pin both
# the helpers' behaviour and the absence of a regression to counter-bound loops.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
    # Source just the helpers — running the script would start a VM.
    eval "$(sed -n '/^deadline_in()/,/^elapsed_min_since()/p' "$E2E")"
}

@test "run-e2e.sh is syntactically valid" {
    run bash -n "$E2E"
    [ "$status" -eq 0 ]
}

@test "deadline_in returns an absolute epoch in the future" {
    local now d
    now=$(date +%s)
    d=$(deadline_in 60)
    [ "$d" -ge $((now + 60)) ]
    [ "$d" -le $((now + 62)) ]
}

@test "past_deadline is false before and true after the deadline" {
    run past_deadline "$(deadline_in 60)"
    [ "$status" -ne 0 ]
    run past_deadline "$(( $(date +%s) - 1 ))"
    [ "$status" -eq 0 ]
}

@test "a deadline elapses in real time even when the loop body blocks" {
    # The whole point: time spent working counts against the budget. Simulate a
    # blocking loop body with sleep and no counter increment at all.
    local d=0 iterations=0
    d=$(deadline_in 2)
    while ! past_deadline "$d"; do
        sleep 1
        iterations=$((iterations + 1))
        [ "$iterations" -gt 10 ] && break
    done
    # A counter-bound loop would never exit here; a wall-clock one exits at ~2s.
    [ "$iterations" -le 4 ]
}

@test "elapsed_min_since reports whole minutes of real time" {
    run elapsed_min_since "$(( $(date +%s) - 125 ))"
    [ "$output" -eq 2 ]
}

# ── regression guards on the harness itself ─────────────────────────────────

@test "no wait loop is bound by a tick counter" {
    # `while [ $ELAPSED -lt $TIMEOUT ]` is the exact shape that caused the drift.
    #
    # This assertion was originally written case-SENSITIVE and so passed while
    # three lowercase loops (qga_wait, qga_wait_windows) were still counter
    # bound — a test that looked green while covering none of them. Match
    # case-insensitively; a guard that only catches the naming convention you
    # happened to think of is not a guard.
    run grep -nEi 'while \[ "?\$[a-z_]*elapsed"? -lt' "$E2E"
    [ "$status" -ne 0 ]
    run grep -nE 'while .*\$[A-Z_]*ELAPSED.*-lt.*\$[A-Z_]*TIMEOUT' "$E2E"
    [ "$status" -ne 0 ]
}

@test "the long-running loops use past_deadline" {
    # deploy, OEM barrier, Windows install, Phase-2 boot.
    local n
    n=$(grep -c 'while ! past_deadline' "$E2E")
    [ "$n" -ge 7 ]
}

@test "progress lines report real minutes against the real budget" {
    # "Deploying... (49m)" with no budget was unactionable; show both.
    grep -q 'Deploying\.\.\. (${NOW_MIN}m of \$((TIMEOUT/60))m)' "$E2E"
}

@test "every QGA call is bounded by a timeout" {
    # A wall-clock deadline cannot rescue a loop whose body never returns.
    # An unbounded `podman exec` froze two runners for 20+ minutes with their
    # progress line stuck, while the script still showed as running.
    grep -q 'timeout "$QGA_CALL_TIMEOUT" $DOCKER exec' "$E2E"
}

@test "the QGA call timeout is overridable for slow hosts" {
    grep -q 'WOOTC_QGA_CALL_TIMEOUT' "$E2E"
}

@test "Phase-2 boot failure reports actual waited time, not the nominal budget" {
    # It claimed "did not boot within 5 minutes" after waiting considerably
    # longer, which sent debugging after a boot-speed problem that did not exist.
    grep -q 'did not boot within \$(elapsed_min_since' "$E2E"
}
