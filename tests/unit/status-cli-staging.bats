#!/usr/bin/env bats
setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT_DIR="$BATS_TEST_TMPDIR/runner"
    mkdir -p "$SCRIPT_DIR/wootc-files"
    fail() { echo "$*" >&2; }
    eval "$(sed -n '/^prepare_status_cli() {/,/^}/p' "$ROOT/tests/e2e/run-e2e.sh")"
}
@test "missing status CLI fails before VM setup" {
    run prepare_status_cli
    [ "$status" -ne 0 ]
    [[ "$output" == *'Required status CLI missing'* ]]
    [ ! -e "$SCRIPT_DIR/wootc-files/wootc.exe.sha256" ]
}
@test "CLI checksum matches staged bytes and deleting binary fails again" {
    printf fixture > "$SCRIPT_DIR/wootc-files/wootc.exe"
    prepare_status_cli
    expected=$(sha256sum "$SCRIPT_DIR/wootc-files/wootc.exe" | cut -d ' ' -f1)
    [ "$(cat "$SCRIPT_DIR/wootc-files/wootc.exe.sha256")" = "$expected" ]
    rm "$SCRIPT_DIR/wootc-files/wootc.exe"
    run prepare_status_cli
    [ "$status" -ne 0 ]
}
@test "guest checks CLI before partitioning and BCD arming" {
    setup="$ROOT/tests/e2e/setup-wootc.ps1"
    cli=$(grep -n '^Copy-WootcStatusCLI ' "$setup" | cut -d: -f1)
    disk=$(grep -n 'New-Partition\|bcdedit /copy' "$setup" | head -1 | cut -d: -f1)
    [ "$cli" -lt "$disk" ]
    grep -q 'wootc.exe.sha256.*OEM_PAYLOAD' "$ROOT/tests/e2e/run-e2e.sh"
}
