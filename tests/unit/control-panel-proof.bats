#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }
@test "Windows UI receipts reject missing, stale and falsely passed rendered fields" {
    run python3 -m unittest discover -s "$ROOT/tests/unit" -p test_control_panel_receipt.py -v
    [ "$status" -eq 0 ]
}

load_ui_gate() {
    eval "$(awk '/^verify_installed_boot_gui\(\)/ {capture=1} capture {print} capture && /^}$/ {exit}' "$ROOT/tests/e2e/run-e2e.sh")"
    ARTIFACT_DIR="$BATS_TEST_TMPDIR"
    RUN_ID="current-test-run"
    FIRSTBOOT_RECORD_FILE="$BATS_TEST_TMPDIR/observed.json"
    fail() { printf '%s\n' "$*" >&2; }
    gui_prepare_account() { touch "$BATS_TEST_TMPDIR/fixture-mutated"; }
    qga_call() { touch "$BATS_TEST_TMPDIR/guest-write"; }
}

@test "Windows UI proof refuses guest staging before positive Windows identity" {
    load_ui_gate
    qga_windows_probe() { return 1; }
    run verify_installed_boot_gui
    [ "$status" -ne 0 ]
    [[ "$output" == *"positive Windows identity"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/fixture-mutated" ]
    [ ! -e "$BATS_TEST_TMPDIR/guest-write" ]
}

@test "Windows UI proof refuses fixture changes when independent Linux facts are absent" {
    load_ui_gate
    qga_windows_probe() { return 0; }
    printf '{"current":{"kernel":"6.12"}}' > "$FIRSTBOOT_RECORD_FILE"
    run verify_installed_boot_gui
    [ "$status" -ne 0 ]
    [[ "$output" == *"Independent first-boot UI facts unavailable"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/fixture-mutated" ]
    [ ! -e "$BATS_TEST_TMPDIR/guest-write" ]
}
