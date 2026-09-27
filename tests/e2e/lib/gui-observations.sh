#!/usr/bin/env bash
# Source-only GUI transition observations; no product verdict follows ping loss.
wootc_gui_observations_configure() {
    [ "$#" -eq 2 ] && declare -F "$1" >/dev/null && declare -F "$2" >/dev/null || return 2
    WOOTC_GUI_OBSERVATION_CALL="$1"
    WOOTC_GUI_OBSERVATION_BOUNDARY="$2"
}
wootc_gui_observation_call() {
    local remaining=$((WOOTC_GUI_OBSERVATION_DEADLINE - $(date +%s)))
    [ "$remaining" -gt 0 ] || return 124
    [ "$remaining" -le 5 ] || remaining=5
    WOOTC_QGA_CALL_TIMEOUT="$remaining" "${WOOTC_GUI_OBSERVATION_CALL:?Configure GUI observations first}" "$@"
}
gui_handover_sample() {
    local observed
    WOOTC_GUI_HANDOVER_OBSERVATION=unknown
    # Failed commands with plausible stdout do not establish identity.
    # shellcheck disable=SC2016
    if observed=$(wootc_gui_observation_call powershell '$env:OS' 2>/dev/null); then
        observed=$(printf '%s' "$observed" | tr -d '\r\n')
        if [ "$observed" = Windows_NT ]; then
            "${WOOTC_GUI_OBSERVATION_BOUNDARY:?Configure GUI observations first}"
            WOOTC_GUI_HANDOVER_OBSERVATION=windows
            return 0
        fi
    fi
    if observed=$(wootc_gui_observation_call exec /bin/sh -c 'uname -s' 2>/dev/null); then
        observed=$(printf '%s' "$observed" | tr -d '\r\n')
        if [ "$observed" = Linux ]; then
            WOOTC_GUI_HANDOVER_OBSERVATION=linux
            return 0
        fi
    fi
    # This is only channel unavailability, never proof of reboot or Linux.
    if ! wootc_gui_observation_call ping >/dev/null 2>&1; then
        [ "$(date +%s)" -lt "$WOOTC_GUI_OBSERVATION_DEADLINE" ] || return 124
        WOOTC_GUI_HANDOVER_OBSERVATION=transport-unavailable
    fi
}
gui_wait_handover() {
    local budget="${1-180}" remaining pause
    [[ "$budget" =~ ^[1-9][0-9]*$ ]] || return 2
    WOOTC_GUI_OBSERVATION_DEADLINE=$(( $(date +%s) + budget ))
    while [ "$(date +%s)" -lt "$WOOTC_GUI_OBSERVATION_DEADLINE" ]; do
        gui_handover_sample || break
        case "$WOOTC_GUI_HANDOVER_OBSERVATION" in
            linux|transport-unavailable) return 0 ;;
        esac
        remaining=$((WOOTC_GUI_OBSERVATION_DEADLINE - $(date +%s)))
        [ "$remaining" -gt 0 ] || break
        pause=10
        [ "$remaining" -ge "$pause" ] || pause="$remaining"
        sleep "$pause"
    done
    infra_fail "GUI handover could not be observed within the deadline (last observation: ${WOOTC_GUI_HANDOVER_OBSERVATION:-unknown})"
    return 1
}

gui_write_reboot_directive() {
    local observed remaining
    WOOTC_GUI_OBSERVATION_DEADLINE=$(( $(date +%s) + 60 ))
    # shellcheck disable=SC2016
    observed=$(wootc_gui_observation_call powershell '$env:OS' 2>/dev/null) || {
        infra_fail "GUI reboot directive requires positive Windows identity"; return 1;
    }
    observed=$(printf '%s' "$observed" | tr -d '\r\n')
    [ "$observed" = Windows_NT ] || {
        infra_fail "GUI reboot directive requires positive Windows identity"; return 1;
    }
    "${WOOTC_GUI_OBSERVATION_BOUNDARY:?Configure GUI observations first}"
    remaining=$((WOOTC_GUI_OBSERVATION_DEADLINE - $(date +%s)))
    [ "$remaining" -gt 0 ] || { infra_fail "GUI reboot directive deadline expired before write"; return 1; }
    # One write only; a failed or timed-out side effect is never replayed.
    # shellcheck disable=SC2016
    observed=$(WOOTC_QGA_CALL_TIMEOUT="$remaining" "${WOOTC_GUI_OBSERVATION_CALL:?Configure GUI observations first}" powershell '
$ErrorActionPreference = "Stop"
$directive = "{`"action`":`"reboot`"}"
Set-Content -LiteralPath C:\wootc\e2e-drive.json -Value $directive -Encoding ascii
$readback = Get-Content -LiteralPath C:\wootc\e2e-drive.json -Raw
if ($readback.Trim() -ne $directive) { throw "GUI reboot directive readback mismatch" }
Write-Output "gui-reboot-directive-written"
' 2>/dev/null) || { infra_fail "GUI reboot directive write/readback failed; handover refused"; return 1; }
    observed=$(printf '%s' "$observed" | tr -d '\r\n')
    [ "$observed" = gui-reboot-directive-written ] || {
        infra_fail "GUI reboot directive acknowledgment is unknown; handover refused"; return 1;
    }
}
