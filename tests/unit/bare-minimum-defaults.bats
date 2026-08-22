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

@test "Wi-Fi collection runs outside the WindowsLook gate" {
    # Wi-Fi migrates unconditionally — being online on first boot without
    # re-typing passwords must not hinge on a desktop-look preference.
    # Extract the collect step and require collectWifi BEFORE the look gate.
    body="$(awk '/Collecting your look and Wi-Fi/,/^\t\t\}\},$/' "$REPO_ROOT/app/app.go")"
    wifi_line="$(printf '%s\n' "$body" | grep -n 'collectWifi()' | head -1 | cut -d: -f1)"
    gate_line="$(printf '%s\n' "$body" | grep -n 'if cfg.WindowsLook' | head -1 | cut -d: -f1)"
    [ -n "$wifi_line" ] && [ -n "$gate_line" ]
    [ "$wifi_line" -lt "$gate_line" ]
}
