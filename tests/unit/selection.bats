#!/usr/bin/env bats
# selection.bats — the migration chooser's opt-out must actually gate the
# bridges. Before wootc-selection existed, migration-selection.json was written
# by the GUI and read by nobody: switching a category off still migrated it.
# These tests pin the contract the bridges rely on.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SEL="$REPO_ROOT/payload/migration/wootc-selection"
    export WOOTC_SELECTION="$BATS_TEST_TMPDIR/migration-selection.json"
}

write_sel() {  # write_sel <category> <true|false>
    python3 - "$WOOTC_SELECTION" "$1" "$2" <<'PY'
import json, sys
path, cat, on = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
json.dump({"version": 1, "selection": {"Alex": {cat: {"on": on, "items": {}}}}}, open(path, "w"))
PY
}

@test "no selection file at all → everything migrates (default on)" {
    rm -f "$WOOTC_SELECTION"
    run "$SEL" alex games
    [ "$status" -eq 0 ]
}

@test "category explicitly ON → migrates" {
    write_sel games true
    run "$SEL" alex games
    [ "$status" -eq 0 ]
}

@test "category explicitly OFF → skipped (this is the bug that was unwired)" {
    write_sel games false
    run "$SEL" alex games
    [ "$status" -eq 1 ]
}

@test "turning one category off does not disable the others" {
    write_sel games false
    run "$SEL" alex office
    [ "$status" -eq 0 ]
}

@test "unreadable/corrupt selection fails open (never blocks a migration)" {
    printf 'not json' > "$WOOTC_SELECTION"
    run "$SEL" alex games
    [ "$status" -eq 0 ]
}

@test "the GUI's own default selection keeps every discovered category on" {
    # mirror what wootc-manifest-gui writes when the user changes nothing
    python3 - "$WOOTC_SELECTION" <<'PY'
import json, sys
cats = {c: {"on": True, "items": {}} for c in ("files", "browsers", "games", "wifi")}
json.dump({"version": 1, "selection": {"Alex": cats}}, open(sys.argv[1], "w"))
PY
    for c in files browsers games wifi; do
        run "$SEL" alex "$c"
        [ "$status" -eq 0 ]
    done
}
