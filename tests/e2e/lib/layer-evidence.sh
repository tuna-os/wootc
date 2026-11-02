# shellcheck shell=bash
# Layer observations reuse results.sh's sole result authority. Source after
# results.sh; sourcing performs no guest call, reset, or result mutation.
WOOTC_LAYER_EVIDENCE_BACKEND="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/layer-evidence.py"

wootc_layer_record() { # <kind> <domain> <layer> <fixed observation code>
    wootc_result_record "${WOOTC_RESULT_LEDGER:?Initialize run results first}" "${RUN_ID:?}" \
        "$1" "$2" "layer-$3" "" "layer=$3 observation=$4"
}

wootc_layer_failure() { # <layer> <domain> <fixed cause code>
    case "$1:$2" in
        qga-control:infrastructure|e2e-runner:runner|windows-oem:product|windows-oem:infrastructure|deployer:product|deployer:infrastructure) ;;
        *) return 2 ;;
    esac
    [[ "$3" =~ ^[a-z0-9-]+$ ]] || return 2
    wootc_layer_record failure "$2" "$1" "$3"
}

# Call immediately after the runner's existing direct reset_oem_attempt call.
# Do not wrap that reset in an if/||: doing so disables its internal errexit.
wootc_layer_reset_observed() {
    wootc_layer_record assertion infrastructure fixture-reset reset-completed
}

wootc_layer_qga() {
    local observed
    if ! observed=$(WOOTC_QGA_CALL_TIMEOUT=5 qga_call info 2>/dev/null); then
        wootc_layer_failure qga-control infrastructure guest-info-unavailable || return 1
        return 1
    fi
    if ! printf '%s' "$observed" | python3 "$WOOTC_LAYER_EVIDENCE_BACKEND" qga >/dev/null; then
        wootc_layer_failure qga-control infrastructure guest-info-rejected || return 1
        return 1
    fi
    # guest-info is control-plane evidence, NOT Windows/Linux identity or a
    # successful install, so never records a product assertion.
    wootc_layer_record assertion infrastructure qga-control guest-info-observed
}

wootc_layer_oem() { # <actual e2e-setup-complete.txt content, CRLF normalized>
    [ -n "${RUN_ID:-}" ] && [ "$1" = "$RUN_ID" ] || return 1
    wootc_layer_record assertion product windows-oem current-run-staged
}

wootc_layer_deployer() { # <oem|gui> <actual OEM marker|empty for GUI> <started JSON path> <lifecycle JSON path>
    local observation
    if ! observation=$(python3 "$WOOTC_LAYER_EVIDENCE_BACKEND" deployer \
        "${WOOTC_RESULT_LEDGER:?}" "${RUN_ID:?}" "$1" "$2" "${IMAGE_REF:?}" \
        "${RUN_STARTED_AT:?}" "$3" "$4"); then
        wootc_layer_failure deployer infrastructure unbound-lifecycle-observation || return 1
        return 1
    fi
    if [ "$observation" = deployer-failed ]; then
        wootc_layer_failure deployer product lifecycle-failed || return 1
        return 1
    fi
    [ "$observation" = deployer-observed ] || return 2
    wootc_layer_record assertion product deployer lifecycle-observed
}
