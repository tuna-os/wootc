#!/usr/bin/env bats

@test "BitLocker fixture readiness requires exact observations within its wall-clock deadline" {
    run python3 "$BATS_TEST_DIRNAME/test_bitlocker_readiness.py"
    [ "$status" -eq 0 ]
}
