# shellcheck shell=bash
# Configure(runtime executable, container name, guest client path) before use.
# Callbacks: info/warn/pass/step/infra_fail/note_flake, deadline_in/past_deadline,
# and wootc_phase_boundary. Existing timeout/reconnect environment knobs apply.
# Sourcing defines functions; it makes no guest request.
wootc_qga_configure() {
    [ "$#" -eq 3 ] && [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 2
    WOOTC_QGA_RUNTIME="$1"
    WOOTC_QGA_CONTAINER="$2"
    WOOTC_QGA_CLIENT="$3"
}
wootc_qga_valid_timeout() {
    case "$1" in ''|*[!0-9]*) return 2 ;; esac
    [ "$1" -gt 0 ] || return 2
}
WOOTC_QGA_TRANSPORT_EXIT=42
WOOTC_QGA_RECONNECT_ATTEMPTS="${WOOTC_QGA_RECONNECT_ATTEMPTS:-3}"
WOOTC_QGA_RECONNECT_SETTLE_S="${WOOTC_QGA_RECONNECT_SETTLE_S:-3}"

qga_call() {
    local timeout_s="${WOOTC_QGA_CALL_TIMEOUT-60}"
    wootc_qga_valid_timeout "$timeout_s" || return 2
    local rc=0
    # `else rc=$?` is load-bearing (#39). Assigning rc AFTER the `fi`
    # captures the exit status of the IF STATEMENT, not of the command —
    # and an `if` whose condition failed with no else branch is itself
    # status 0. So the old form returned SUCCESS once every retry had
    # failed:
    #     f(){ for i in 1 2; do if false; then return 0; fi; rc=$?; done; return $rc; }
    #     f; echo $?   # -> 0
    # That made qga_probe/qga_wait able to print "[PASS] QGA available"
    # with no agent answering, and let failed PowerShell/file-write/exec
    # requests look successful — the project's dominant failure class,
    # status taken from a proxy instead of the real observable.
    if timeout "$timeout_s" "${WOOTC_QGA_RUNTIME:?Configure QGA first}" exec "${WOOTC_QGA_CONTAINER:?Configure QGA first}" python3 "${WOOTC_QGA_CLIENT:?Configure QGA first}" "$@"; then
        return 0
    else
        rc=$?
    fi
    return $rc
}


qga_call_retry() {
    local timeout_s="${WOOTC_QGA_CALL_TIMEOUT-60}"
    wootc_qga_valid_timeout "$timeout_s" || return 2
    local tries=3 rc=0 try
    if [ "$timeout_s" -le 5 ]; then tries=1; fi
    # shellcheck disable=SC2034
    for try in $(seq 1 $tries); do
        if timeout "$timeout_s" "${WOOTC_QGA_RUNTIME:?Configure QGA first}" exec "${WOOTC_QGA_CONTAINER:?Configure QGA first}" python3 "${WOOTC_QGA_CLIENT:?Configure QGA first}" "$@"; then
            return 0
        else
            rc=$?
        fi
        # Only retry transport errors (QGA never received the request) and
        # timeouts (ambiguous). Never retry a guest exit code — doing so
        # would replay side-effecting commands like shutdown, reboot, or
        # BCD mutation (#40).
        if [ "$rc" -ne "$WOOTC_QGA_TRANSPORT_EXIT" ] && [ "$rc" -ne 124 ]; then
            return $rc
        fi
        sleep 1
    done
    return $rc
}


qga_probe() {
    WOOTC_QGA_CALL_TIMEOUT=5 qga_call_retry ping >/dev/null 2>&1 || return 1
}


qga_reconnect_cycle() {
    local out rc=0
    warn "  QGA channel is not answering — ONE bounded reconnect cycle before any verdict"
    # Clients that outlived their `timeout` may still hold the single-client
    # socket. Reaping them is a prerequisite for the reopen, not an extra.
    timeout 5 "${WOOTC_QGA_RUNTIME:?Configure QGA first}" exec "${WOOTC_QGA_CONTAINER:?Configure QGA first}" pkill -f "$WOOTC_QGA_CLIENT" >/dev/null 2>&1 || true
    sleep 1
    out=$(timeout 60 "${WOOTC_QGA_RUNTIME:?Configure QGA first}" exec "${WOOTC_QGA_CONTAINER:?Configure QGA first}" python3 "${WOOTC_QGA_CLIENT:?Configure QGA first}" reconnect \
        --attempts "$WOOTC_QGA_RECONNECT_ATTEMPTS" \
        --settle "$WOOTC_QGA_RECONNECT_SETTLE_S" 2>&1) || rc=$?
    # An `x && y` tail would be the last status of this block under `set -e`,
    # and an empty $out would abort the whole run from inside the recovery path.
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | sed 's/^/    reconnect: /'
    fi
    if [ "$rc" -eq 0 ]; then
        pass "  QGA channel RECOVERED — the stall was the channel, and it is back"
        return 0
    fi
    return 1
}


qga_channel_lost() {
    local where="$1"
    infra_fail "CLASSIFICATION: qga-channel-lost — the QGA channel died during $where"
    infra_fail "  QGA does NOT answer ping, and one bounded reconnect cycle did not bring the channel back."
    infra_fail "  This run has NO verdict on the product: the install may have finished, stalled or failed,"
    infra_fail "  and with the channel deaf the harness cannot tell — so it does not guess."
    note_flake "qga-channel-lost"
}


qga_wait() {
    local label="$1" timeout="$2" elapsed=0
    step "Waiting for QGA: $label..."
    local deadline; deadline=$(deadline_in "$timeout")
    while ! past_deadline "$deadline"; do
        if qga_probe; then
            pass "QGA available: $label"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        [ $((elapsed % 60)) -eq 0 ] && info "Waiting for QGA ($label)... ($(( elapsed / 60 ))m)"
    done
    infra_fail "QGA did not become available for $label within $((timeout / 60)) minutes"
    return 1
}


qga_wait_down() {
    local label="$1" timeout="${2:-120}" elapsed=0
    info "Waiting for Windows QGA to go away before $label..."
    local deadline; deadline=$(deadline_in "$timeout")
    while ! past_deadline "$deadline"; do
        if ! qga_windows_probe; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    infra_fail "Windows QGA did not go away before $label"
    return 1
}


qga_wait_reboot() {
    local label="$1"
    qga_wait_down "$label" 120
    qga_wait "$label" 600
}


# GUI session callers invoke this callback by its configured name and pass the
# remaining deadline; direct callers use the default five-second budget.
# shellcheck disable=SC2120
qga_windows_probe() {
    local os probe_timeout="${1-5}"
    wootc_qga_valid_timeout "$probe_timeout" || return 2
    [ "$probe_timeout" -le 5 ] || probe_timeout=5
    os=$(WOOTC_QGA_CALL_TIMEOUT="$probe_timeout" qga_powershell '$env:OS' 2>/dev/null) || return 1
    os=$(printf '%s' "$os" | tr -d '\r\n')
    if [[ "$os" == Windows_NT ]]; then
        # A phase observed in the Linux guest cannot describe a Windows action.
        wootc_phase_boundary
        return 0
    fi
    return 1
}


qga_linux_probe() {
    local os
    os=$(WOOTC_QGA_CALL_TIMEOUT=5 qga_call exec /bin/sh -c 'uname -s' 2>/dev/null) || return 1
    os=$(printf '%s' "$os" | tr -d '\r\n')
    [[ "$os" == Linux ]]
}


p2_reboot_observe() {
    local budget="${WOOTC_E2E_P2_REBOOT_TRIES:-9}" poll="${WOOTC_E2E_P2_REBOOT_POLL_S:-5}" i
    # shellcheck disable=SC2034
    for i in $(seq 1 "$budget"); do
        if [ "$poll" -gt 0 ]; then sleep "$poll"; fi
        qga_probe || { echo down; return 0; }
        if qga_windows_probe; then echo windows; return 0; fi
    done
    if qga_linux_probe; then echo linux; else echo unknown; fi
}


qga_powershell() {
    qga_call powershell "$1" || return $?
}


qga_read() {
    qga_call_retry read "$1" || return $?
}

