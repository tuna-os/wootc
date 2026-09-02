#!/usr/bin/env bats
# recovery-matrix.bats — Unit tests for the Fault-Injection & Recovery matrix (#288).

ROOT="$BATS_TEST_DIRNAME/../.."
MATRIX_TSV="$ROOT/tests/e2e/matrix.tsv"
RUN_MATRIX="$ROOT/tests/e2e/run-matrix.sh"
RUN_E2E="$ROOT/tests/e2e/run-e2e.sh"
SETUP_WOOTC="$ROOT/tests/e2e/setup-wootc.ps1"
ASSERT_RECOVERY="$ROOT/tests/e2e/assert-recovery.ps1"
RUN_RECOVERY="$ROOT/tests/e2e/run-recovery-matrix.sh"
DEPLOY_SH="$ROOT/payload/deployer/deploy.sh"
HOSTED_WF="$ROOT/.github/workflows/e2e-hosted.yml"
MATRIX_WF="$ROOT/.github/workflows/e2e-matrix.yml"

@test "matrix.tsv covers all 6 fault injection boundaries" {
    for boundary in "image-pull" "root-disk" "efi-staging" "bcd-arming" "pre-reboot" "deploy-failure"; do
        grep -E "fault=${boundary}" "$MATRIX_TSV" || {
            echo "Missing fault boundary in matrix.tsv: $boundary" >&2
            return 1
        }
    done
}

@test "matrix.tsv smoke tier includes critical recovery cells" {
    run grep -E "^smoke.*fault=image-pull" "$MATRIX_TSV"
    [ "$status" -eq 0 ]
    run grep -E "^smoke.*fault=bcd-arming" "$MATRIX_TSV"
    [ "$status" -eq 0 ]
    run grep -E "^smoke.*fault=deploy-failure" "$MATRIX_TSV"
    [ "$status" -eq 0 ]
}

@test "run-matrix.sh threads fault= opts to --fault-inject and env var" {
    grep -q 'WOOTC_E2E_FAULT_INJECT' "$RUN_MATRIX"
    grep -q 'fault=\*) echo .--fault-inject=' "$RUN_MATRIX"
}

@test "run-e2e.sh accepts --fault-inject flag and handles recovery check" {
    grep -q '\--fault-inject=\*) FAULT_INJECT=' "$RUN_E2E"
    grep -q 'recovery_check' "$RUN_E2E"
    grep -q 'FaultInject=' "$RUN_E2E"
    grep -q 'assert-recovery.ps1' "$RUN_E2E"
}

@test "setup-wootc.ps1 supports -FaultInject parameter for all boundaries" {
    grep -q '\[string\]\$FaultInject' "$SETUP_WOOTC"
    grep -q 'root-disk' "$SETUP_WOOTC"
    grep -q 'image-pull' "$SETUP_WOOTC"
    grep -q 'efi-staging' "$SETUP_WOOTC"
    grep -q 'bcd-arming' "$SETUP_WOOTC"
    grep -q 'pre-reboot' "$SETUP_WOOTC"
}

@test "setup-wootc.ps1 sweeps stale BCD entries for retry idempotency" {
    grep -q 'identifier.*description.*wootc' "$SETUP_WOOTC"
    grep -q 'bcdedit /delete' "$SETUP_WOOTC"
}

@test "deploy.sh reads wootc.fault and records failed state" {
    grep -q 'read_cmdline wootc.fault' "$DEPLOY_SH"
    grep -q 'deploy-failure' "$DEPLOY_SH"
    grep -q '"state":"failed"' "$DEPLOY_SH"
}

@test "assert-recovery.ps1 validates interrupted, retried, and uninstalled stages" {
    [ -f "$ASSERT_RECOVERY" ]
    grep -q 'interrupted' "$ASSERT_RECOVERY"
    grep -q 'retried' "$ASSERT_RECOVERY"
    grep -q 'uninstalled' "$ASSERT_RECOVERY"
    grep -q 'winload' "$ASSERT_RECOVERY"
    grep -q 'bootsequence' "$ASSERT_RECOVERY"
}

@test "run-recovery-matrix.sh is executable and accepts parameters" {
    [ -x "$RUN_RECOVERY" ]
    run bash "$RUN_RECOVERY" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Usage:" ]]
}

@test "e2e-hosted.yml and e2e-matrix.yml support fault_inject" {
    grep -q 'fault_inject:' "$HOSTED_WF"
    grep -q '\--fault-inject=' "$HOSTED_WF"
    grep -q 'fault_inject' "$MATRIX_WF"
}
