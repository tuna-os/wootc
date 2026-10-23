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

@test "the control-panel proof restarts Windows only through the observed-restart helper" {
    # E2E 39931657846: the account-repair restart called qga_wait_reboot with
    # no pre-request boot observation, which the transport refuses.
    local runner="$BATS_TEST_DIRNAME/../e2e/run-e2e.sh" body
    body=$(sed -n '/^verify_installed_boot_gui() {/,/^}/p' "$runner")
    [[ "$body" == *'qga_restart_windows "Windows UI fixture account repair"'* ]]
    [[ "$body" != *'shutdown.exe /r'* ]]
    # Every restart wait in the runner carries a baseline: none is called directly.
    run grep -nE '^[^#]*\bqga_wait_reboot\b' "$runner"
    [ "$status" -ne 0 ]
}

# The gate after the session check, with every guest operation stubbed.
# READY: whether e2e-ready.json appears; SINGLE: the single-instance answer.
drive_ui_gate() {
    load_ui_gate
    # shellcheck source=tests/e2e/lib/gui-session.sh
    source "$ROOT/tests/e2e/lib/gui-session.sh"
    SCRIPT_DIR="$ROOT/tests/e2e"; DOCKER=true; CONTAINER_NAME=c
    GUI_ACCOUNT_RESTART=false
    qga_windows_probe() { return 0; }
    gui_prepare_account() { return 0; }
    gui_wait_interactive_session() { return 0; }
    qga_call() { [[ "$*" == *e2e-drive.json* ]] && touch "$BATS_TEST_TMPDIR/directive-written"; return 0; }
    qga_powershell() {
        case "$1" in
            *launch-control-panel-proof*) echo control-panel-task-run ;;
            *wootc-control-proof*) printf '%s\n' "$SINGLE" ;;
        esac
    }
    qga_read() { [[ "$1" == *e2e-ready.json ]] && [ "$READY" = yes ]; }
    deadline_in() { echo 2; }
    T=0; past_deadline() { T=$((T + 1)); [ "$T" -gt "$1" ]; }
    sleep() { :; }
    printf '{"current":{"kernel":"6.12","image":{"sourceRef":"ghcr.io/x/y:z"},"bridge":{"boundFolders":1,"matchedUsers":1}}}' \
        > "$FIRSTBOOT_RECORD_FILE"
    run verify_installed_boot_gui
}

@test "a control panel that never renders is a named failure before any directive" {
    READY=no SINGLE='' drive_ui_gate
    [ "$status" -ne 0 ]
    [[ "$output" == *"Control-panel proof: wootc.exe did not render within 90 s"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/directive-written" ]
}

@test "a second control panel or a surviving launch task is a named failure before any directive" {
    # E2E 39961283836: two wootc.exe after the ONCE trigger fired; the run
    # ended with no [FAIL] line.
    for single in $'task-absent: wootc-control-proof\nSINGLE-INSTANCE-UNPROVEN: 2 wootc.exe running' \
                  $'TASK-STILL-PRESENT: wootc-control-proof survived its delete\nsingle-instance: 1 wootc.exe' \
                  $'task-absent: wootc-gui-e2e\nsingle-instance: 1 wootc.exe' ''; do
        rm -f "$BATS_TEST_TMPDIR/directive-written"
        READY=yes SINGLE="$single" drive_ui_gate
        [ "$status" -ne 0 ]
        [[ "$output" == *"Control-panel proof: cannot prove one control panel"* ]]
        [ ! -e "$BATS_TEST_TMPDIR/directive-written" ]
    done
    # One proven control panel proceeds to the directive.
    READY=yes SINGLE=$'task-absent: wootc-control-proof\nsingle-instance: 1 wootc.exe' drive_ui_gate
    [ -e "$BATS_TEST_TMPDIR/directive-written" ]
}

@test "the control-panel gate has no unnamed exit and launches without a future trigger" {
    local body
    body=$(sed -n '/^verify_installed_boot_gui() {/,/^}/p' "$ROOT/tests/e2e/run-e2e.sh")
    # Every `return 1` follows a fail on its own line or the line before it.
    printf '%s\n' "$body" | awk '/return 1/ && !/fail / && prev !~ /fail / { print "unnamed exit: " $0; bad=1 } { prev=$0 } END { exit bad }'
    # Readiness is the directive-free channel, not the bound drive report.
    [[ "$body" == *"e2e-ready.json"* ]]
    local ps1="$ROOT/tests/e2e/launch-control-panel-proof.ps1"
    grep -q "AddMinutes(-1)" "$ps1"
    run grep -q "AddMinutes(1)" "$ps1"
    [ "$status" -ne 0 ]
}
