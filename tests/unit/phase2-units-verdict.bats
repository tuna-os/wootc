#!/usr/bin/env bats
# The Phase-2 failed-unit verdict (tests/e2e/lib/phase2-units.sh).
# Probe 44878928655: tuned.service failed, the check printed ~100 KiB of
# core-dump journal after the FAIL line, `printf | grep -q` hit a broken pipe
# under pipefail, and the run said "failed without a product finding".

setup() {
    # shellcheck source=tests/e2e/lib/phase2-units.sh
    source "$BATS_TEST_DIRNAME/../e2e/lib/phase2-units.sh"
    # A failed unit, then more journal than a pipe buffer (64 KiB) holds, and
    # less than one execve argument (128 KiB) so the tests can pass it to bash.
    BIG="FAIL: unit failed: tuned.service"$'\n'
    BIG+=$(head -c 120000 /dev/zero | tr '\0' 'x' | fold -w 200)
}

@test "a failed unit with a large journal is a product finding, not a check error" {
    run bash -c 'set -Eeuo pipefail; source "$1"; phase2_units_verdict 1 "$2"' _ \
        "$BATS_TEST_DIRNAME/../e2e/lib/phase2-units.sh" "$BIG"
    [ "$status" -eq 0 ]
    [ "$output" = failed-units ]
}

@test "the premise holds: printf | grep -q fails under pipefail on that output" {
    run bash -c 'set -o pipefail; printf "%s\n" "$1" | grep -q "^FAIL:"' _ "$BIG"
    [ "$status" -ne 0 ]
}

@test "still booting, check error and clean keep their verdicts" {
    [ "$(phase2_units_verdict 3 'SCHEMA=1')" = still-booting ]
    [ "$(phase2_units_verdict 2 'SCHEMA=1')" = check-error ]
    [ "$(phase2_units_verdict 0 'SCHEMA=1')" = clean ]
}
