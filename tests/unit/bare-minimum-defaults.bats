#!/usr/bin/env bats
# bare-minimum-defaults.bats — the launchpad's ask-almost-nothing contract.
#
# The default form asks for a password and nothing else; everything else is a
# solid default the user can trust (identity mirrored from the PC, disk sized
# from free space, look + Wi-Fi brought along). The Playwright suite pins the
# form's shape; these pin the two wiring facts a JS refactor can silently
# lose without any visible form change.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

@test "the launchpad sends windowsLook with the install config" {
    # The checkbox existed for weeks while startInstall never sent the field:
    # the backend gated look collection on a value that always arrived false,
    # so no real GUI install ever brought the look (or Wi-Fi) along. The
    # field must travel with the config.
    grep -q 'windowsLook:.*state\.config\.windowsLook' \
        "$REPO_ROOT/app/frontend/src/screens/launchpad.js"
}

wifi_precedes_look_gate() {
    local body="$1" wifi_line gate_line
    wifi_line="$(printf '%s\n' "$body" | grep -n 'collectWifi()' | head -1 | cut -d: -f1)"
    gate_line="$(printf '%s\n' "$body" | grep -n 'if cfg.WindowsLook' | head -1 | cut -d: -f1)"
    [ -n "$wifi_line" ] && [ -n "$gate_line" ] || return 1
    [ "$wifi_line" -lt "$gate_line" ]
}

@test "Wi-Fi collection runs outside the WindowsLook gate" {
    # Wi-Fi migrates unconditionally: call presence alone is insufficient.
    body="$(awk '/^[[:space:]]*\{StepInstallerCollectingYourLookAndWiFi,/,/^\t\t\}\},$/' "$REPO_ROOT/app/app.go")"
    wifi_precedes_look_gate "$body"
}

@test "Wi-Fi ordering assertion rejects collection moved inside the look gate" {
    body="$(awk '/^[[:space:]]*\{StepInstallerCollectingYourLookAndWiFi,/,/^\t\t\}\},$/' "$REPO_ROOT/app/app.go")"
    # Keep the call present but move it after the gate in a disposable copy.
    mutated="$(printf '%s\n' "$body" | sed '/if err := collectWifi()/d; /if cfg.WindowsLook {/a\                if err := collectWifi(); err != nil {' )"
    run wifi_precedes_look_gate "$mutated"
    [ "$status" -ne 0 ]
    run wifi_precedes_look_gate ""
    [ "$status" -ne 0 ]
}
