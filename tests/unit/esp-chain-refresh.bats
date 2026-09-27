#!/usr/bin/env bats
setup() { REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }
@test "actual ESP consumer refuses preflight before any artifact writes" {
    run python3 "$REPO_ROOT/tests/unit/test_esp_chain_refresh.py"
    [ "$status" -eq 0 ]
}
@test "legacy issuer-only trust API cannot authorize publication" {
    run python3 "$REPO_ROOT/tests/unit/test_shim_trust.py"
    [ "$status" -eq 0 ]
}
@test "transaction restores whole trio and checks actual ownership" {
    run python3 "$REPO_ROOT/tests/unit/test_wootc_esp_transaction.py"
    [ "$status" -eq 0 ]
}
@test "fresh current boot rejects native ancestry and wrong ESP" {
    run python3 "$REPO_ROOT/tests/unit/test_wootc_boot_identity.py"
    [ "$status" -eq 0 ]
}
@test "complete signed-chain payload closure is mandatory during staging" {
    run python3 "$REPO_ROOT/tests/unit/test_wootc_chain_staging.py"
    [ "$status" -eq 0 ]
}
