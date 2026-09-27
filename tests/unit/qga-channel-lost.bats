#!/usr/bin/env bats
# The QGA-channel-loss failure class (#220).
#
# The exemplar is el10-gnome-win11pro in run 32556250889: the drive-state file
# stopped changing, the harness waited out its full 30-minute deadline, and
# then reported "install stalled at Finding your files" — with the dead-ping
# caveat printed underneath the verdict it invalidated. A deaf virtio-serial
# channel and a stalled installer produce the SAME observable and opposite
# causes, so the channel has to be asked before anything is written down, and
# what gets written must name the class rather than the product.
#
# The recovery itself (drain, reopen, bounded give-up) is exercised against a
# real killed socket in tests/unit/test_qga_reconnect.py. Here the two harness
# helpers are sourced and RUN against a stubbed container, and the wiring that
# reaches them is pinned statically.

E2E=tests/e2e/run-e2e.sh
QGA=tests/e2e/qga.py
TRANSPORT=tests/e2e/lib/qga-transport.sh

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    ABS_E2E="$REPO_ROOT/$E2E"
    # Source just the helpers — running the script would start a VM.
    source "$REPO_ROOT/tests/e2e/lib/results.sh"
    source "$REPO_ROOT/tests/e2e/lib/result-runner.sh"
    eval "$(sed -n '/^note_flake()/,/^}/p' "$ABS_E2E")"
    source "$REPO_ROOT/$TRANSPORT"

    STORAGE_DIR="$BATS_TEST_TMPDIR/storage"; mkdir -p "$STORAGE_DIR"
    WOOTC_FAILURE_LEDGER="$BATS_TEST_TMPDIR/ledger"; : > "$WOOTC_FAILURE_LEDGER"
    WOOTC_RESULT_LEDGER="$BATS_TEST_TMPDIR/results.jsonl"
    RUN_ID=qga-test
    wootc_result_init "$WOOTC_RESULT_LEDGER" "$RUN_ID" full-cycle
    CONTAINER_NAME="stub-ctr"
    STUB_LOG="$BATS_TEST_TMPDIR/stub.log"; : > "$STUB_LOG"
    export STORAGE_DIR WOOTC_FAILURE_LEDGER WOOTC_RESULT_LEDGER RUN_ID STUB_LOG
    # A stand-in for podman/docker: records what it was asked to run and takes
    # the reconnect exit code from the environment.
    DOCKER="$BATS_TEST_TMPDIR/docker"
    cat > "$DOCKER" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$*" in
    *pkill*)              exit "${STUB_PKILL_RC:-1}" ;;
    *"qga.py reconnect"*) printf '%s' "${STUB_RECONNECT_OUT-}"
                          exit "${STUB_RECONNECT_RC:-0}" ;;
esac
exit 0
STUB
    chmod +x "$DOCKER"
    wootc_qga_configure "$DOCKER" "$CONTAINER_NAME" /tmp/qga.py
    export DOCKER CONTAINER_NAME
}

@test "the reconnect cycle reports a channel that came back" {
    STUB_RECONNECT_RC=0 STUB_RECONNECT_OUT="attempt 1/3: channel answered guest-ping"
    export STUB_RECONNECT_RC STUB_RECONNECT_OUT
    run qga_reconnect_cycle
    [ "$status" -eq 0 ]
    [[ "$output" == *"RECOVERED"* ]]
    [[ "$output" == *"reconnect: attempt 1/3"* ]]
    # Stale clients are reaped BEFORE the reopen, not after: while one holds
    # the single-client socket the reopen cannot succeed.
    run cat "$STUB_LOG"
    [[ "${lines[0]}" == *pkill* ]]
    [[ "${lines[1]}" == *"qga.py reconnect"* ]]
    [[ "${lines[1]}" == *"--attempts 3"* ]]
    [[ "${lines[1]}" == *"--settle 3"* ]]
}

@test "the reconnect cycle claims nothing when the channel stays deaf" {
    STUB_RECONNECT_RC=42
    STUB_RECONNECT_OUT="attempt 3/3: timed out"
    export STUB_RECONNECT_RC STUB_RECONNECT_OUT
    run qga_reconnect_cycle
    [ "$status" -eq 1 ]
    [[ "$output" != *"RECOVERED"* ]]
}

@test "the recovery path cannot itself kill the run under set -e" {
    # run-e2e.sh runs under `set -Eeuo pipefail`, so every non-zero step inside
    # the recovery has to be absorbed deliberately. Both of the ordinary ones
    # are: pkill exits 1 when there is nothing stale to reap (the common case),
    # and a reconnect that fails is the whole reason this function exists. An
    # unabsorbed either would abort the run from inside its own rescue, and
    # bats `run` cannot see it — set -e is suspended in a tested call — so this
    # invokes the function as a bare statement.
    local probe="$BATS_TEST_TMPDIR/probe.sh"
    {
        echo 'set -Eeuo pipefail'
        sed -n "/^RED='/,/^NC='/p" "$ABS_E2E"
        printf 'source %q\n' "$REPO_ROOT/tests/e2e/lib/results.sh"
        printf 'source %q\n' "$REPO_ROOT/tests/e2e/lib/result-runner.sh"
        printf 'source %q\n' "$REPO_ROOT/$TRANSPORT"
        echo 'wootc_qga_configure "$DOCKER" "$CONTAINER_NAME" /tmp/qga.py'
        # Bare, NOT `|| true`: set -e is suspended inside a tested call, which
        # is exactly the leniency this test exists to deny itself.
        echo 'qga_reconnect_cycle'
        echo 'echo "SURVIVED"'
    } > "$probe"
    # Nothing stale to reap, channel comes back: runs to completion.
    STUB_PKILL_RC=1 STUB_RECONNECT_RC=0 STUB_RECONNECT_OUT="attempt 1/3: ok" run bash "$probe"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SURVIVED"* ]]
    # Channel stays deaf: the only non-zero the caller may see is the
    # function's own verdict, reached AFTER the reconnect actually ran. An
    # unabsorbed pkill or capture aborts before that line is ever printed.
    STUB_PKILL_RC=1 STUB_RECONNECT_RC=42 STUB_RECONNECT_OUT="attempt 3/3: timed out" run bash "$probe"
    [ "$status" -eq 1 ]
    [[ "$output" == *"reconnect: attempt 3/3: timed out"* ]]
    [[ "$output" != *"RECOVERED"* ]]
}

@test "the verdict lands in BOTH the ledger and the machine-readable file" {
    run qga_channel_lost "the GUI-driven install"
    [ "$status" -eq 0 ]
    # The retry gate reads this file; nothing else re-dispatches a run.
    [ "$(cat "$STORAGE_DIR/flake-verdict.txt")" = "qga-channel-lost" ]
    # And the ledger NAMES the class, so the decision needs no log-reading.
    grep -q 'CLASSIFICATION: qga-channel-lost' "$WOOTC_FAILURE_LEDGER"
    grep -q 'NO verdict on the product' "$WOOTC_FAILURE_LEDGER"
    # The product-failure wording must not ride along with it.
    ! grep -qi 'did not reach the done screen' "$WOOTC_FAILURE_LEDGER"
}

@test "channel loss is classified, not waited out" {
    # The drive loop's dead-ping branch must reach a verdict. Before #220 it
    # only warn()ed and fell back into the poll, buying ~28 more minutes that
    # cannot make a deaf channel talk.
    run bash -c "grep -A20 'drive state unreadable AND QGA does not answer ping' $E2E"
    [ "$status" -eq 0 ]
    [[ "$output" == *"qga_reconnect_cycle"* ]]
    [[ "$output" == *"qga_channel_lost"* ]]
    [[ "$output" == *"exit 1"* ]]
}

@test "the reconnect cycle runs ONCE, and only before the verdict" {
    # One cycle per run, not one per stall: a second deaf spell is answered
    # with a classification, not another round of dialling.
    grep -q 'local reconnect_tried=false' "$E2E"
    # The in-loop call is fired behind the latch, and the latch is set BEFORE
    # the attempt, so a cycle that dies mid-way cannot be retried either.
    run bash -c "grep -B2 'if qga_reconnect_cycle; then' $E2E"
    [ "$status" -eq 0 ]
    [[ "$output" == *'if [ "$reconnect_tried" = false ]; then'* ]]
    [[ "$output" == *"reconnect_tried=true"* ]]
}

@test "the reconnect cycle reaps stale clients before reopening" {
    # The QGA socket takes ONE client at a time, so a client killed by the
    # `timeout` wrapper can still own it with its reply queued behind — the
    # poisoning caveat from agent-lessons §20. Reaping is part of the reopen.
    run bash -c "source $TRANSPORT; declare -f qga_reconnect_cycle"
    [ "$status" -eq 0 ]
    [[ "$output" == *"pkill"* ]]
    [[ "$output" == *WOOTC_QGA_CLIENT*reconnect* ]]
    # Bounded: an attempt budget and a settle delay, both overridable.
    [[ "$output" == *'--attempts'* ]]
    [[ "$output" == *'--settle'* ]]
    grep -q 'WOOTC_QGA_RECONNECT_ATTEMPTS' "$TRANSPORT"
    grep -q 'WOOTC_QGA_RECONNECT_SETTLE_S' "$TRANSPORT"
}

@test "the verdict names the class and claims nothing about the product" {
    run bash -c "source $TRANSPORT; declare -f qga_channel_lost"
    [ "$status" -eq 0 ]
    # The ledger line NAMES the class, so re-dispatch needs no human to read
    # the log — fail() is what appends to WOOTC_FAILURE_LEDGER.
    [[ "$output" == *"CLASSIFICATION: qga-channel-lost"* ]]
    [[ "$output" == *'note_flake "qga-channel-lost"'* ]]
    # ...and it explicitly withholds a product verdict it cannot support.
    [[ "$output" == *"NO verdict on the product"* ]]
}

@test "the 30-minute timeout leads with the channel, not with the product" {
    # The old order printed "did not reach the done screen in 30m" first and
    # appended "the verdict above may be a lost channel" underneath. The
    # discriminator has to come FIRST because it decides which verdict is even
    # available.
    run bash -c "grep -A12 'GUI-driven install did not reach the done screen' $E2E"
    [ "$status" -eq 0 ]
    # A live channel is still a real product red, and writes no flake verdict.
    [[ "$output" == *"QGA answers ping"* ]]
    [[ "$output" != *"note_flake"* ]]
    # The channel-lost arm is gated on BOTH a dead ping and a failed reconnect.
    grep -q 'if ! qga_probe && ! qga_reconnect_cycle; then' "$E2E"
}

@test "a channel that comes back is not a failure" {
    # The recovery path must resume the poll, not fall through to a verdict:
    # a transient stall the reconnect fixes is a run that continues.
    run bash -c "grep -A6 'if qga_reconnect_cycle; then' $E2E | head -8"
    [ "$status" -eq 0 ]
    [[ "$output" == *"continue"* ]]
}

@test "qga.py: a socket that will not open is TRANSPORT, not a guest exit code" {
    # Exit 1 from a dead channel is indistinguishable from a guest command that
    # ran and returned 1, so qga_call_retry refused to retry it (#40 forbids
    # replaying guest exit codes) and callers read the dead channel as a real
    # product failure — the masquerade this issue is about.
    run bash -c "grep -A5 'agent = GuestAgent(args.socket)' $QGA"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cannot open"* ]]
    [[ "$output" == *"TRANSPORT_EXIT"* ]]
}

@test "qga.py: the reconnect cycle drains before it syncs" {
    # guest-sync-delimited re-anchors the response stream, but only once the
    # backlog ahead of it is gone — and the leftovers are raw socket bytes, so
    # the drain must happen before makefile() joins them onto a real reply.
    run bash -c "sed -n '/def __init__(self, path=SOCKET/,/self._sync()/p' $QGA"
    [ "$status" -eq 0 ]
    [[ "$output" == *"self._drain("* ]]
    run bash -c "grep -n 'self._drain(drain_grace)' $QGA"
    [ "$status" -eq 0 ]
    drain_line=$(grep -n 'self.drained = self._drain' "$QGA" | cut -d: -f1)
    makefile_line=$(grep -n 'self.file = self.sock.makefile' "$QGA" | cut -d: -f1)
    [ "$drain_line" -lt "$makefile_line" ]
}

@test "the synthetic channel-kill test exists and runs in the fast tier" {
    [ -f tests/unit/test_qga_reconnect.py ]
    # tests/run.sh globs tests/unit/test_*.py, so the name is the wiring.
    grep -q 'tests/unit/test_\*\.py' tests/run.sh
    run python3 tests/unit/test_qga_reconnect.py
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}
