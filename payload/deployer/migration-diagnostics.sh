#!/bin/bash
# Local JSON diagnostics for the initramfs phase boundary. Inputs are fixed
# phase IDs and exit codes only; never pass commands, image refs or vault data.
WOOTC_DIAGNOSTIC_PHASE=""
WOOTC_DIAGNOSTIC_AT=0
WOOTC_DIAGNOSTIC_ATTEMPT=""
read -r WOOTC_DIAGNOSTIC_ATTEMPT < /proc/sys/kernel/random/boot_id || true

wootc_diagnostic_millis() {
    local uptime fraction
    read -r uptime _ < /proc/uptime || return 1
    fraction="${uptime#*.}000"
    printf '%s\n' "$(( ${uptime%.*} * 1000 + 10#${fraction:0:3} ))"
}

wootc_diagnostic_emit() { # <phase> <event> <elapsed ms> [fixed error code]
    local phase="$1" event="$2" elapsed="$3" code="${4:-}" line
    # All fields are engine-controlled; refuse arbitrary diagnostic strings.
    [[ "$phase" =~ ^[a-z0-9-]+$ ]] || return 0
    [[ "$WOOTC_DIAGNOSTIC_ATTEMPT" =~ ^[a-f0-9-]+$ ]] || return 0
    printf -v line '{"timestamp":"%s","attemptId":"%s","phase":"%s","event":"%s","duration_ms":%s,"error_code":"%s"}' \
        "$(date -u +%FT%TZ)" "$WOOTC_DIAGNOSTIC_ATTEMPT" "$phase" "$event" "$elapsed" "$code"
    printf '%s\n' "$line" >&2 || true
    if [[ -n "${PERSIST_LOG:-}" ]]; then
        printf '%s\n' "$line" >> "$PERSIST_LOG" 2>/dev/null || true
    fi
}

wootc_diagnostic_phase() { # <fixed deployer phase ID>
    local now
    now=$(wootc_diagnostic_millis) || return 0
    if [[ -n "$WOOTC_DIAGNOSTIC_PHASE" ]]; then
        wootc_diagnostic_emit "$WOOTC_DIAGNOSTIC_PHASE" phase_complete "$((now - WOOTC_DIAGNOSTIC_AT))"
    fi
    WOOTC_DIAGNOSTIC_PHASE="$1"
    WOOTC_DIAGNOSTIC_AT="$now"
    wootc_diagnostic_emit "$1" phase_start 0
}

wootc_diagnostic_finish() { # <deployer exit status>
    local now event=phase_complete code=""
    [[ -n "$WOOTC_DIAGNOSTIC_PHASE" ]] || return 0
    now=$(wootc_diagnostic_millis) || return 0
    if [[ "$1" != 0 ]]; then event=phase_error; code=operation_failed; fi
    wootc_diagnostic_emit "$WOOTC_DIAGNOSTIC_PHASE" "$event" "$((now - WOOTC_DIAGNOSTIC_AT))" "$code"
    WOOTC_DIAGNOSTIC_PHASE=""
}
