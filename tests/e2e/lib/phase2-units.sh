# shellcheck shell=bash
# Source-only: the verdict of the Phase-2 failed-unit check.
#
# phase3-health.sh phase2-units prints one "FAIL: unit failed: <unit>" line
# per failed unit outside the known-failure list, each followed by the unit's
# status and journal (often hundreds of KiB of core-dump stack traces). It
# exits 3 while Phase 2 is still booting.
#
# The output is matched from a here-string, never `printf | grep -q`: grep -q
# exits at the first FAIL line, printf then writes into a closed pipe, and
# under `set -o pipefail` the pipeline fails. A real failed unit was reported
# as "failed without a product finding" (probe 44878928655).

# phase2_units_verdict <check exit status> <check output>
#   Prints one word: failed-units, still-booting, check-error or clean.
phase2_units_verdict() {
    local status="$1" output="$2"
    if grep -q '^FAIL:' <<<"$output"; then
        echo failed-units
    elif [ "$status" -eq 3 ]; then
        echo still-booting
    elif [ "$status" -ne 0 ]; then
        echo check-error
    else
        echo clean
    fi
}
