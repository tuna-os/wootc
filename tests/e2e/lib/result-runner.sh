# shellcheck shell=bash
# Logging adapter: caller supplies run paths; this module starts no VM.
wootc_report_abort() {
    local rc="$1" cmd="$2"
    # fail+exit sites have already printed their own reason.
    case "$cmd" in exit*) return 0 ;; esac
    printf '[FAIL] run-e2e.sh aborted: %s (exit %s)\n' "$cmd" "$rc" >&2
    if [ -n "${WOOTC_RESULT_LEDGER:-}" ]; then
        wootc_result_record "$WOOTC_RESULT_LEDGER" "$RUN_ID" failure runner "" "" "$cmd (exit $rc)" || return 1
    fi
}

pass() { printf '%b[PASS]%b %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*"; }
# Every fail() is RECORDED, and the final banner is gated on the ledger being
# empty. Until now fail() only echoed: a fail site that did not itself `exit 1`
# was decorative, and the run sailed on to "ALL TESTS PASSED".
#
# That is not hypothetical. el10-gnome-win11pro-bitlocker (20260727T004500Z)
# printed ALL TESTS PASSED with BOTH of these in its log:
#     [FAIL] Passthrough: errors detected in boot output:
#     [FAIL] User data NOT visible in Phase 2 $HOME (expected RUN_ID ...)
# The second is the North Star itself — the whole product claim is that the
# user's data survives — and the matrix recorded the case as PASS. Both sites
# set PASSTHROUGH_OK=false, but nothing anywhere gated on that variable.
#
# The ledger is a FILE, not a variable: fail() is called from inside command
# substitutions and pipelines, whose variable writes are lost with the subshell.
fail() {
    # printf '%b' the COLOURS, '%s' the MESSAGE. `echo -e` interpreted escapes
    # in the message too, so any Windows path was corrupted in the one place it
    # mattered most: "C:\\OEM\\run-wootc-e2e.ps1" printed as
    # "C:\\OEMun-wootc-e2e.ps1" because \r became a carriage return. \t, \n and
    # \b mangle just as silently.
    printf '%b[FAIL]%b %s\n' "$RED" "$NC" "$*" >&2
    printf '%s\n' "$*" >> "$WOOTC_FAILURE_LEDGER" || return 1
    wootc_result_record "$WOOTC_RESULT_LEDGER" "$RUN_ID" failure "${WOOTC_FAILURE_DOMAIN:-runner}" "" "${WOOTC_CURRENT_PHASE_ID:-}" "$*" || return 1
    if [ -n "${WOOTC_PHASE_LEDGER:-}" ] && [ -n "${WOOTC_CURRENT_PHASE_ID:-}" ]; then
        if [ "${WOOTC_FAILURE_DOMAIN:-runner}" = product ]; then wootc_phase_record failed "$WOOTC_CURRENT_PHASE_ID" "$*" || return 1; fi
    fi
}
infra_fail() { WOOTC_FAILURE_DOMAIN=infrastructure fail "$@"; }
product_fail() { WOOTC_FAILURE_DOMAIN=product fail "$@"; }
product_pass() {
    local assertion="$1"; shift
    wootc_result_record "$WOOTC_RESULT_LEDGER" "$RUN_ID" assertion product "$assertion" "${WOOTC_CURRENT_PHASE_ID:-}" "$*" || return 1
    pass "$@"
}
info() { printf '%b[INFO]%b %s\n' "$YELLOW" "$NC" "$*"; }
