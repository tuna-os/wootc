#!/usr/bin/env bats
# matrix.bats — the E2E matrix must actually cover the axes it claims, and the
# runner must actually deliver per-case knobs to the runs.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    MATRIX="$REPO_ROOT/tests/e2e/matrix.tsv"
    RUNNER="$REPO_ROOT/tests/e2e/run-matrix.sh"
}

@test "matrix covers Windows 10 and 11, Home and Pro" {
    awk -F'\t' '!/^#/ && $4=="11" && $5=="pro"'  "$MATRIX" | grep -q .
    awk -F'\t' '!/^#/ && $4=="10" && $5=="pro"'  "$MATRIX" | grep -q .
    awk -F'\t' '!/^#/ && $4=="11" && $5=="home"' "$MATRIX" | grep -q .
    awk -F'\t' '!/^#/ && $4=="10" && $5=="home"' "$MATRIX" | grep -q .
}

@test "matrix covers the BitLocker axis including Home device-encryption" {
    grep -v '^#' "$MATRIX" | grep 'bitlocker=on' | grep -q $'\thome\t'
    grep -v '^#' "$MATRIX" | grep 'bitlocker=on' | grep -q $'\tpro\t'
}

@test "matrix covers all three deployment backends" {
    # traditional ostree, composefs-SEALED ostree, composefs-native.
    grep -v '^#' "$MATRIX" | grep -q 'tuna-os/yellowfin'
    grep -v '^#' "$MATRIX" | grep -q 'projectbluefin/bluefin:lts'
    grep -v '^#' "$MATRIX" | grep -q 'projectbluefin/dakota'
}

@test "matrix has a phase3 case per backend flavor" {
    grep -v '^#' "$MATRIX" | grep 'phase3=on' | grep -q 'yellowfin'
    grep -v '^#' "$MATRIX" | grep 'phase3=on' | grep -q 'bluefin:lts'
    grep -v '^#' "$MATRIX" | grep 'phase3=on' | grep -q 'dakota'
}

@test "host_worker threads the opts column through to run_case" {
    # It previously read five fields and passed a stale $opts global from the
    # planning loop — bitlocker=on silently never reached any run.
    grep -q 'while IFS=\$'"'"'\\t'"'"' read -r name image ver ed key opts; do' "$RUNNER"
    grep -q 'run_case "\$host" "\$name" "\$image" "\$ver" "\$ed" "\$key" "\$opts"' "$RUNNER"
}

@test "phase3=on translates to --phase3 on the remote invocation" {
    grep -q 'phase3=on\*) EXTRA_ARGS="--phase3"' "$RUNNER"
    grep -q 'run-e2e.sh "\$image" --keep \\\$EXTRA_ARGS' "$RUNNER"
}
