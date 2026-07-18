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
