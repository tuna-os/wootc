#!/usr/bin/env bats
# apply-look.bats — Windows-Style Mode exit-code contract (SPEC §4.4).
#
# Regression guard: a successful look-apply MUST exit 0 and write its once-only
# marker even when there are no taskbar pins / desktop shortcuts to place.
# Previously the script ended on `[[ $placed -gt 0 ]] && log …`, which returns
# non-zero when nothing was placed; under `set -e` that aborted the script
# before the marker was written — so look re-applied on every boot and any
# caller under `set -e` (the deployer, the integration suite) saw a failure.
#
# Dry-run mode needs only python3, so this runs on the host.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    AL="$REPO_ROOT/payload/migration/wootc-apply-look"
    SLURP="$BATS_TEST_TMPDIR/slurp"; mkdir -p "$SLURP"
    MARKER="$BATS_TEST_TMPDIR/marker"
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
    export WOOTC_DRYRUN=1 WOOTC_SLURP_DIR="$SLURP" WOOTC_LOOK_MARKER="$MARKER"
}

@test "GNOME look-apply exits 0 and writes the marker with no pins" {
    printf '{"wallpaper":"w.jpg","darkMode":"true","accentColor":"#E62D42"}\n' >"$SLURP/slurp.json"
    touch "$SLURP/w.jpg"
    XDG_CURRENT_DESKTOP=GNOME run bash "$AL"
    [ "$status" -eq 0 ]
    [ -f "$MARKER" ]
    grep -q "applied=gnome" "$MARKER"
    [[ "$output" == *"prefer-dark"* ]]
    [[ "$output" == *"accent-color red"* ]]
}

@test "KDE look-apply exits 0 with no pins" {
    printf '{"darkMode":"true"}\n' >"$SLURP/slurp.json"
    XDG_CURRENT_DESKTOP=KDE run bash "$AL"
    [ "$status" -eq 0 ]
    [ -f "$MARKER" ]
    grep -q "applied=kde" "$MARKER"
}

@test "unknown desktop still exits 0 and records the marker (mapped=none)" {
    printf '{"darkMode":"true"}\n' >"$SLURP/slurp.json"
    XDG_CURRENT_DESKTOP=SomeWM run bash "$AL"
    [ "$status" -eq 0 ]
    grep -q "applied=none" "$MARKER"
}

@test "the once-only marker suppresses a second apply" {
    printf '{"darkMode":"true"}\n' >"$SLURP/slurp.json"
    XDG_CURRENT_DESKTOP=GNOME run bash "$AL"
    [ "$status" -eq 0 ]
    XDG_CURRENT_DESKTOP=GNOME run bash "$AL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already applied"* ]]
}

@test "no slurp data is a clean exit 0" {
    XDG_CURRENT_DESKTOP=GNOME run bash "$AL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to apply"* ]]
}

# ── taskbar pins → dock/panel (SPEC §4.4) ──────────────────────────────────
# Install the .desktop files the pins resolve to so resolve_desktop finds them.
install_apps() {
    local appdir="$HOME/.local/share/applications"; mkdir -p "$appdir"
    printf '[Desktop Entry]\nName=%s\n' "$2" > "$appdir/$1.desktop"
}
slurp_with_pins() {
    printf '{"darkMode":"true","taskbarApps":[{"exe":"firefox.exe","name":"Firefox"},{"exe":"steam.exe","name":"Steam"}]}\n' >"$SLURP/slurp.json"
}

@test "GNOME dock favorites built from taskbar pins (refactor regression guard)" {
    slurp_with_pins; install_apps firefox Firefox; install_apps steam Steam
    XDG_CURRENT_DESKTOP=GNOME run bash "$AL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"favorite-apps"* ]]
    [[ "$output" == *"'firefox.desktop'"* ]]
    [[ "$output" == *"'steam.desktop'"* ]]
    [[ "$output" == *"dock favorites set from 2 taskbar pins"* ]]
}

@test "KDE panel launchers built from the same pins, targeting the task-manager applet" {
    slurp_with_pins; install_apps firefox Firefox; install_apps steam Steam
    # a Plasma appletsrc whose task-manager applet lives at a non-default index
    mkdir -p "$HOME/.config"
    cat >"$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" <<'CFG'
[Containments][2][Applets][7]
plugin=org.kde.plasma.icontasks

[Containments][2][Applets][9]
plugin=org.kde.plasma.systemtray
CFG
    XDG_CURRENT_DESKTOP=KDE run bash "$AL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"kwriteconfig6"* ]]
    # must target the discovered applet group, not a guessed one
    [[ "$output" == *"--group Containments --group 2 --group Applets --group 7 --group Configuration --group General"* ]]
    [[ "$output" == *"launchers applications:firefox.desktop,applications:steam.desktop"* ]]
    [[ "$output" == *"panel launchers set from 2 taskbar pins"* ]]
}

@test "KDE favorites fall back to a default group when no appletsrc exists" {
    slurp_with_pins; install_apps firefox Firefox; install_apps steam Steam
    XDG_CURRENT_DESKTOP=KDE run bash "$AL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"task-manager applet not found"* ]]
    [[ "$output" == *"--group Containments --group 1 --group Applets --group 1"* ]]
}

@test "XFCE is retired (X11/out of scope) — clean exit, mapped=none" {
    printf '{"darkMode":"true"}\n' >"$SLURP/slurp.json"
    XDG_CURRENT_DESKTOP=XFCE run bash "$AL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"X11/out of scope"* ]]
    grep -q "applied=none" "$MARKER"
    # never emit an xfconf command
    [[ "$output" != *"xfconf-query"* ]]
}
