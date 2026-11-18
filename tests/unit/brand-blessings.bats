#!/usr/bin/env bats
# Upstream blessings (#227) — the release matrix follows the recorded decision.
#
# Every branded exe wears somebody else's mark. `app/branding/*/blessing.json`
# records what that project said, and packaging/brands.sh is what makes the
# record load-bearing rather than documentary: a declined project's exe drops
# out of the release, and a brand nobody has written a record for cannot be
# built at all.
#
# The Go side (app/blessing_test.go) validates the records themselves — that a
# status agrees with its own four answers, and that a foreign mark cannot be
# marked blessed without a link to the yes. These tests cover the shell gate
# and the artifacts offered to the projects.

BRANDS=packaging/brands.sh
RENDER=packaging/winget/render-brand.sh
RELEASE=.github/workflows/release.yml

setup() {
    FIXTURE="$BATS_TEST_TMPDIR/branding"
    cp -r app/branding "$FIXTURE"
}

# Rewrites one field of a fixture brand's blessing record.
fixture_set() {
    python3 -c '
import json, sys
path, expr = sys.argv[1], sys.argv[2]
d = json.load(open(path))
exec(expr, {"d": d})
json.dump(d, open(path, "w"), indent=2)
' "$FIXTURE/$1/blessing.json" "$2"
}

@test "the real tree lists every brand that has not been declined" {
    run bash "$BRANDS" list
    [ "$status" -eq 0 ]
    # One line per brand, "<brand><TAB><exeName>".
    [[ "$output" == *$'wootc\twootc'* ]]
    [[ "$output" == *$'bazzite\tBazzite-Installer'* ]]
    [[ "$output" == *$'aurora\tAurora-Installer'* ]]
    [[ "$output" == *$'bluefin\tBluefin-Installer'* ]]
    [[ "$output" == *$'tunaos\tTunaOS-Installer'* ]]
    [ "${#lines[@]}" -eq 5 ]
}

@test "a declined project's exe drops out of the release matrix" {
    fixture_set bazzite 'd["status"]="declined"; d["decisions"]["distributeExe"]="no"'
    WOOTC_BRANDING_DIR="$FIXTURE" run bash "$BRANDS" list
    [ "$status" -eq 0 ]
    [[ "$output" != *"Bazzite-Installer"* ]]
    [[ "$output" == *"Aurora-Installer"* ]]
    # ...and the log says whose decision it was, not just that a build vanished.
    WOOTC_BRANDING_DIR="$FIXTURE" run bash "$BRANDS" explain
    [ "$status" -eq 0 ]
    [[ "$output" == *"DROPPED"* ]]
    [[ "$output" == *"bazzite"* ]]
    [[ "$output" == *"not ours to ship"* ]]
}

@test "a brand with no recorded decision is an error, not a default yes" {
    # The failure mode this whole mechanism exists to prevent: someone adds
    # app/branding/<x>/ and it ships on nobody's say-so.
    mkdir -p "$FIXTURE/newbrand"
    cp app/branding/wootc/brand.json "$FIXTURE/newbrand/brand.json"
    WOOTC_BRANDING_DIR="$FIXTURE" run bash "$BRANDS" list
    [ "$status" -ne 0 ]
    [[ "$output" == *"no blessing.json"* ]]
    [[ "$output" == *"recorded decision"* ]]
}

@test "an unrecognised status is an error, never treated as buildable" {
    fixture_set aurora 'd["status"]="probably fine"'
    WOOTC_BRANDING_DIR="$FIXTURE" run bash "$BRANDS" list
    [ "$status" -ne 0 ]
    [[ "$output" == *"not blessed/pending/declined"* ]]
}

@test "WOOTC_REQUIRE_BLESSING tightens pending brands out without a code change" {
    WOOTC_BRANDING_DIR="$FIXTURE" WOOTC_REQUIRE_BLESSING=1 run bash "$BRANDS" list
    [ "$status" -eq 0 ]
    # Only the two marks this project owns survive today.
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" == *"wootc"* ]]
    [[ "$output" == *"TunaOS-Installer"* ]]
    [[ "$output" != *"Bazzite-Installer"* ]]
}

@test "a pending brand still builds, and the log says it is unblessed" {
    # Shipping predates the ask, so pending is not a stop — but a release that
    # quietly includes an unblessed exe teaches nobody to chase the answer.
    WOOTC_BRANDING_DIR="$FIXTURE" run bash "$BRANDS" explain
    [ "$status" -eq 0 ]
    [[ "$output" == *"UNBLESSED"* ]]
    [[ "$output" == *"docs/upstream-blessings.md"* ]]
}

@test "the native release workflow selects brands through the gate, not a bare glob" {
    local workflow=.github/workflows/winui-preview.yml
    run bash -c "grep -A28 'Select brands and name the native release assets' $workflow"
    [ "$status" -eq 0 ]
    [[ "$output" == *"packaging/brands.sh list"* ]]
    # The old unconditional loop must stay gone: it built whatever existed.
    run bash -c "grep -c 'for dir in app/branding/\*/' $workflow"
    [ "$output" = "0" ]
    # The selector's exit status must reach the step. A process substitution
    # would drop it and half-build the matrix.
    grep -q 'brands=$(bash packaging/brands.sh list)' "$workflow"
}

@test "every brand renders a complete winget manifest set" {
    while IFS=$'\t' read -r brand _; do
        run bash "$RENDER" "$brand" 0.2.0 https://example.invalid/x.exe deadbeef
        [ "$status" -eq 0 ]
        # A placeholder that survives rendering is a manifest that would be
        # rejected — and worse, one we might hand to a project as our offer.
        [[ "$output" != *"{{"* ]]
        [[ "$output" == *"PackageIdentifier:"* ]]
    done < <(bash "$BRANDS" list)
}

@test "a rendered manifest never claims a permission nobody has granted" {
    # bazzite is pending: the artifact must say so on its face, because this
    # is the thing that gets pasted into somebody else's issue tracker.
    run bash "$RENDER" bazzite
    [ "$status" -eq 0 ]
    [[ "$output" == *"PERMISSION NOT YET GRANTED"* ]]
    [[ "$output" == *"NOT submitted anywhere"* ]]
    [[ "$output" == *"Namespace owner : Universal Blue"* ]]
    [[ "$output" != *"used with the Bazzite project's permission"* ]]
    # Nor does it name Universal Blue as publisher before they said yes.
    [[ "$output" == *'Publisher: "TunaOS"'* ]]
    [[ "$output" != *'Publisher: "Universal Blue"'* ]]
    # The identifier sits in THEIR namespace, not ours.
    [[ "$output" == *"PackageIdentifier: Bazzite.Installer"* ]]
    [[ "$output" != *"PackageIdentifier: TunaOS.Bazzite"* ]]
}

@test "the renderer refuses a brand with no record to offer" {
    run bash "$RENDER" nosuchbrand
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such brand"* ]]
}

@test "no branded package is auto-submitted to winget" {
    # winget-publish.yml is the only thing that submits, and it submits the
    # generic package only. A branded identifier reaching it would be a
    # submission into someone else's namespace on our own authority.
    run bash -c "grep -c 'Bazzite.Installer\|Aurora.Installer\|Bluefin.Installer' .github/workflows/winget-publish.yml"
    [ "$output" = "0" ]
    grep -q 'TunaOS.wootc' .github/workflows/winget-publish.yml
    # The brand templates are rendered on demand, never wired into a workflow.
    run bash -c "grep -rl 'render-brand.sh' .github/workflows/ 2>/dev/null | wc -l"
    [ "$output" = "0" ]
}

@test "the README table and the records cannot drift apart" {
    # The Go suite owns this invariant; this asserts it is actually wired in,
    # so a reader of the shell gate knows where the rest of the line is held.
    grep -q 'TestBrandBlessings_READMETableMatchesTheRecords' app/blessing_test.go
    grep -q 'ForeignMarksNeedEvidence' app/blessing_test.go
    # Every brand directory carries a record right now.
    for dir in app/branding/*/; do
        [ -f "$dir/blessing.json" ] || {
            echo "no blessing.json in $dir"; return 1
        }
    done
}
