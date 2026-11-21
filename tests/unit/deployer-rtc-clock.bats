#!/usr/bin/env bats
# deployer-rtc-clock.bats — Windows keeps the hardware clock in local time;
# the installer records that in install/clock.json (app/clock_handoff.go) and
# the deployer corrects its own clock by the recorded offset, gives the
# installed system /etc/adjtime LOCAL with the Windows zone, and Phase 3
# carries that mode to the native disk. Probe 44869134695: a Windows set to
# Tokyo time made every deployer timestamp 9 hours fast.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    GN="$REPO_ROOT/payload/migration/wootc-go-native"
    GOLDEN="$REPO_ROOT/tests/unit/fixtures/clock-handoff/tokyo.json"
    TMP="$BATS_TEST_TMPDIR"
    CALLS="$TMP/date-calls"
    : >"$CALLS"
    export WOOTC_CLOCK_MARK="$TMP/clock-corrected"
}

# deploy_fn <function>... — the named deploy.sh functions, for eval.
deploy_fn() {
    local f
    for f in "$@"; do sed -n "/^$f() {/,/^}/p" "$DEPLOY"; done
}

# The deployer's logging and date(1), stubbed: the clock reads 15:02:52Z
# (the probe's deployer-started.json) and a set is recorded, not applied.
load_clock() {
    eval "$(deploy_fn correct_rtc_local_clock write_rtc_adjtime)"
    log() { echo "LOG $*"; }
    err() { echo "ERR $*"; }
    date() {
        local args="$*"
        case "$args" in
            "-u +%s") echo 1795359772 ;;
            "-u -s @"*) echo "${args#-u -s @}" >>"$CALLS" ;;
            *) echo 2026-11-21T06:02:52Z ;;
        esac
    }
}

@test "a Windows in Tokyo time moves the deployer clock back 9 hours, once per boot" {
    load_clock
    run correct_rtc_local_clock "$GOLDEN"
    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = "$((1795359772 - 32400))" ]
    [[ "$output" == *"UTC offset 32400s"* ]]
    [ -e "$WOOTC_CLOCK_MARK" ]
    # A second run in the same boot must not subtract the offset again.
    run correct_rtc_local_clock "$GOLDEN"
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$CALLS")" -eq 1 ]
}

@test "a zone west of UTC moves the clock forward" {
    load_clock
    printf '%s\n' '{"schemaVersion":1,"rtcLocal":true,"utcOffsetSeconds":-18000,"timezone":"America/New_York"}' >"$TMP/clock.json"
    run correct_rtc_local_clock "$TMP/clock.json"
    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = "$((1795359772 + 18000))" ]
}

@test "an RTC kept in UTC, a UTC zone or no record leaves the clock alone" {
    load_clock
    printf '%s\n' '{"schemaVersion":1,"rtcLocal":false,"utcOffsetSeconds":32400,"timezone":"Asia/Tokyo"}' >"$TMP/utc.json"
    printf '%s\n' '{"schemaVersion":1,"rtcLocal":true,"utcOffsetSeconds":0,"timezone":"Europe/London"}' >"$TMP/zero.json"
    for record in "$TMP/utc.json" "$TMP/zero.json" "$TMP/absent.json"; do
        run correct_rtc_local_clock "$record"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    [ ! -s "$CALLS" ]
    [ ! -e "$WOOTC_CLOCK_MARK" ]
}

@test "an unreadable record is reported and the clock stays" {
    load_clock
    for body in 'not json' '{"schemaVersion":2,"rtcLocal":true,"utcOffsetSeconds":32400}' \
        '{"schemaVersion":1,"rtcLocal":"yes","utcOffsetSeconds":32400}' \
        '{"schemaVersion":1,"rtcLocal":true,"utcOffsetSeconds":32400.5}' \
        '{"schemaVersion":1,"rtcLocal":true,"utcOffsetSeconds":90000}'; do
        printf '%s\n' "$body" >"$TMP/bad.json"
        run correct_rtc_local_clock "$TMP/bad.json"
        [ "$status" -eq 0 ]
        [[ "$output" == *"clock.json is unreadable"* ]]
    done
    [ ! -s "$CALLS" ]
}

@test "the clock is corrected before the deployer writes its first timestamp" {
    call=$(grep -n '^correct_rtc_local_clock /mnt/ntfs/wootc/install/clock.json$' "$DEPLOY" | cut -d: -f1)
    first_log=$(grep -n '^log "Persistent deployer log started' "$DEPLOY" | cut -d: -f1)
    started=$(grep -n '^write_deployer_started ' "$DEPLOY" | cut -d: -f1)
    state=$(grep -n '^write_ntfs_state ' "$DEPLOY" | head -1 | cut -d: -f1)
    [ -n "$call" ] && [ -n "$first_log" ] && [ -n "$started" ] && [ -n "$state" ]
    [ "$call" -lt "$first_log" ]
    [ "$call" -lt "$started" ]
    [ "$call" -lt "$state" ]
}

@test "the installed system keeps the RTC in local time when Windows does" {
    load_clock
    mkdir -p "$TMP/etc"
    run write_rtc_adjtime "$GOLDEN" "$TMP/etc"
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/etc/adjtime")" = "$(printf '0.0 0 0.0\n0\nLOCAL')" ]
    [[ "$output" == *"Asia/Tokyo"* ]]
    # RTC in UTC, an unmapped zone, or no record: no adjtime, the RTC stays UTC.
    rm "$TMP/etc/adjtime"
    printf '%s\n' '{"schemaVersion":1,"rtcLocal":false,"utcOffsetSeconds":32400,"timezone":"Asia/Tokyo"}' >"$TMP/utc.json"
    printf '%s\n' '{"schemaVersion":1,"rtcLocal":true,"utcOffsetSeconds":20700,"timezone":""}' >"$TMP/unmapped.json"
    for record in "$TMP/utc.json" "$TMP/unmapped.json" "$TMP/absent.json"; do
        run write_rtc_adjtime "$record" "$TMP/etc"
        [ "$status" -eq 0 ]
        [ ! -e "$TMP/etc/adjtime" ]
    done
    grep -q '^    write_rtc_adjtime /mnt/ntfs/wootc/install/clock.json "\$DEPLOY_ROOT/etc"$' "$DEPLOY"
}

@test "the recipe takes the time zone from clock.json when slurp.json has none" {
    eval "$(deploy_fn fisherman_settings_members locale_from_language_tag slurp_recipe_settings)"
    # Windows-Style Mode off: no slurp.json, the zone still reaches the recipe.
    run slurp_recipe_settings "$TMP/absent.json" "$GOLDEN"
    [ "$status" -eq 0 ]
    [ "$output" = '"timezone": "Asia/Tokyo",' ]
    # slurp.json's own zone wins.
    printf '%s\n' '{"timezone":"Europe/Berlin","language":"de-DE","keyboardLayout":"de"}' >"$TMP/slurp.json"
    run slurp_recipe_settings "$TMP/slurp.json" "$GOLDEN"
    [ "$(head -1 <<<"$output")" = '"timezone": "Europe/Berlin",' ]
    grep -Fq 'SETTINGS_JSON=$(slurp_recipe_settings /mnt/ntfs/wootc/install/slurp/slurp.json /mnt/ntfs/wootc/install/clock.json' "$DEPLOY"
}

@test "Phase 3 carries the hardware-clock mode to the native disk" {
    mkdir -p "$TMP/phase2" "$TMP/native" "$TMP/plain" "$TMP/native-plain"
    printf '0.0 0 0.0\n0\nLOCAL\n' >"$TMP/phase2/adjtime"
    run env WOOTC_GN_ETC="$TMP/phase2" bash -c 'source "$1"; carry_rtc_mode "$2"' _ "$GN" "$TMP/native"
    [ "$status" -eq 0 ]
    cmp "$TMP/phase2/adjtime" "$TMP/native/adjtime"
    run env WOOTC_GN_ETC="$TMP/plain" bash -c 'source "$1"; carry_rtc_mode "$2"' _ "$GN" "$TMP/native-plain"
    [ "$status" -eq 0 ]
    [ ! -e "$TMP/native-plain/adjtime" ]
    grep -q 'carry_rtc_mode "\$etcroot"' "$GN"
}
