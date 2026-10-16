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
    local label="$1" budget="$2" deadline remaining pause
    wootc_qga_valid_timeout "$budget" || { infra_fail "Invalid QGA liveness deadline"; return 2; }
    step "Waiting for QGA liveness: $label..."
    deadline=$(( $(date +%s) + budget ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -le 5 ] || remaining=5
        if WOOTC_QGA_CALL_TIMEOUT="$remaining" qga_call ping >/dev/null 2>&1; then
            pass "QGA available (identity unverified): $label"
            return 0
        fi
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -gt 0 ] || break
        pause=10
        [ "$remaining" -ge "$pause" ] || pause="$remaining"
        sleep "$pause"
    done
    infra_fail "QGA liveness unavailable for $label within the deadline"
    return 1
}
qga_wait_down() {
    local label="$1" budget="${2-120}" deadline remaining pause
    wootc_qga_valid_timeout "$budget" || { infra_fail "Invalid QGA departure deadline"; return 2; }
    deadline=$(( $(date +%s) + budget ))
    WOOTC_QGA_DEPARTURE=unknown
    wootc_phase_boundary
    while [ "$(date +%s)" -lt "$deadline" ]; do
        remaining=$((deadline - $(date +%s)))
        if qga_windows_probe "$remaining"; then
            WOOTC_QGA_DEPARTURE=windows
        else
            remaining=$((deadline - $(date +%s)))
            [ "$remaining" -gt 0 ] || break
            if qga_linux_probe "$remaining"; then
                WOOTC_QGA_DEPARTURE=linux
                info "Positive Linux identity observed before $label"
                return 0
            fi
            remaining=$((deadline - $(date +%s)))
            [ "$remaining" -gt 0 ] || break
            [ "$remaining" -le 5 ] || remaining=5
            if ! WOOTC_QGA_CALL_TIMEOUT="$remaining" qga_call ping >/dev/null 2>&1; then
                [ "$(date +%s)" -lt "$deadline" ] || break
                WOOTC_QGA_DEPARTURE=transport-unavailable
                info "QGA transport unavailable before $label; actual boot still requires observation"
                return 0
            fi
            WOOTC_QGA_DEPARTURE=unknown
        fi
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -gt 0 ] || break
        pause=5
        [ "$remaining" -ge "$pause" ] || pause="$remaining"
        sleep "$pause"
    done
    infra_fail "Windows departure could not be observed before $label (last: $WOOTC_QGA_DEPARTURE)"
    return 1
}

# Explicit host parser path; sourcing still performs no runtime/guest operation.
wootc_qga_boot_configure() {
    [ "$#" -eq 1 ] && [[ "$1" = /* ]] && [ -f "$1" ] || return 2
    WOOTC_QGA_BOOT_PARSER="$1"
}
qga_windows_boot_observe() {
    local budget="$1" result
    wootc_qga_valid_timeout "$budget" || return 2
    [ "$budget" -le 5 ] || budget=5
    # shellcheck disable=SC2016
    result=$(WOOTC_QGA_CALL_TIMEOUT="$budget" qga_powershell '
$ErrorActionPreference = "Stop"
if ($env:OS -ne "Windows_NT") { throw "Expected Windows identity" }
$system = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
if ($null -eq $system.LastBootUpTime) { throw "Missing Windows boot observation" }
$bootTime = $system.LastBootUpTime.ToFileTimeUtc()
$record = @{ schemaVersion = 1; os = $env:OS; bootId = "$bootTime" }
$record | ConvertTo-Json -Compress -Depth 3
' 2>/dev/null) || return 1
    result=$(printf '%s' "$result" | python3 "${WOOTC_QGA_BOOT_PARSER:?Configure Windows boot parser first}") || return 1
    printf '%s\n' "$result"
}
qga_wait_reboot() {
    local label="$1" before="${2-}" budget="${3-600}" deadline remaining observed pause
    [[ "$before" =~ ^[1-9][0-9]{8,18}$ ]] && wootc_qga_valid_timeout "$budget" || {
        infra_fail "Windows restart requires a successful pre-request boot observation"; return 2;
    }
    deadline=$(( $(date +%s) + budget ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        remaining=$((deadline - $(date +%s)))
        if observed=$(qga_windows_boot_observe "$remaining"); then
            wootc_phase_boundary
            if [ "$observed" != "$before" ]; then
                pass "Windows new boot observed: $label"
                return 0
            fi
        fi
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -gt 0 ] || break
        pause=5
        [ "$remaining" -ge "$pause" ] || pause="$remaining"
        sleep "$pause"
    done
    infra_fail "Windows new boot could not be observed for $label within the deadline"
    return 1
}
qga_restart_windows() {
    local label="$1" budget="${2-600}" deadline remaining before requested
    wootc_qga_valid_timeout "$budget" || { infra_fail "Invalid Windows restart deadline"; return 2; }
    deadline=$(( $(date +%s) + budget ))
    wootc_phase_boundary
    before=$(qga_windows_boot_observe "$budget") || {
        infra_fail "Windows restart baseline is unknown; request refused: $label"; return 1;
    }
    wootc_phase_boundary
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || { infra_fail "Windows restart deadline expired before request"; return 1; }
    [ "$remaining" -le 60 ] || remaining=60
    # One request only. Failure/timeout is ambiguous and must not be replayed.
    # shellcheck disable=SC2016
    requested=$(WOOTC_QGA_CALL_TIMEOUT="$remaining" qga_powershell '
$ErrorActionPreference = "Stop"
cmd.exe /d /c "shutdown.exe /a >NUL 2>&1"
shutdown.exe /r /t 1 /f
if ($LASTEXITCODE -ne 0) { throw "Windows restart request refused" }
Write-Output "windows-restart-requested"
' 2>/dev/null) || { infra_fail "Windows restart request failed: $label"; return 1; }
    requested=$(printf '%s' "$requested" | tr -d '\r\n')
    [ "$requested" = windows-restart-requested ] || {
        infra_fail "Windows restart request acknowledgment is unknown: $label"; return 1;
    }
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || { infra_fail "Windows restart deadline expired after request"; return 1; }
    qga_wait_reboot "$label" "$before" "$remaining"
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
    local os budget="${1-5}"
    wootc_qga_valid_timeout "$budget" || return 2
    [ "$budget" -le 5 ] || budget=5
    os=$(WOOTC_QGA_CALL_TIMEOUT="$budget" qga_call exec /bin/sh -c 'uname -s' 2>/dev/null) || return 1
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

