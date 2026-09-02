#!/usr/bin/env bats
# step-catalogue.bats — one vocabulary for the words a user watches (#334).
#
# The phase names live in four places: the Phase-1 pipeline (app/app.go), the
# progress screen's list, the deployer's splash table, and the harness's
# markers. Nothing held them together, and they HAD drifted: five pipeline
# steps were missing from the screen, and one entry on the screen was never
# emitted, so it stayed grey for the whole install — which to a nervous user
# reads as a step that did not happen.
#
# The installer/frontend half is enforced by app/steps_test.go, which compares
# the two lists directly. These cover the deployer half.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CAT="$REPO_ROOT/payload/steps.tsv"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
}

catalogued() { # <id> <owner>
    grep -qP "^\Q$1\E\t$2\t" "$CAT"
}

@test "the catalogue exists and names an owner for every entry" {
    [ -f "$CAT" ]
    run awk -F'\t' '!/^#/ && NF && $2 != "installer" && $2 != "deployer" { print }' "$CAT"
    [ -z "$output" ]
}

@test "every phase the deployer announces is catalogued" {
    # A phase() call with no catalogue entry is a word the user can see that
    # nothing else in the tree knows about.
    local missing=""
    while read -r id; do
        catalogued "$id" deployer || missing="$missing $id"
    done < <(grep -oE '^\s*phase "[a-z0-9-]+"' "$DEPLOY" | grep -oE '"[a-z0-9-]+"' | tr -d '"' | sort -u)
    [ -z "$missing" ] || { echo "uncatalogued deployer phases:$missing"; false; }
}

@test "every catalogued deployer phase has a splash line" {
    # A phase with no splash entry freezes the bar on the previous message,
    # which is the "is it stuck?" moment the splash exists to prevent.
    local splash missing=""
    splash=$(sed -n '/case "$1" in/,/esac/p' "$DEPLOY")
    while read -r id; do
        printf '%s' "$splash" | grep -qE "^\s+${id}\)" || missing="$missing $id"
    done < <(awk -F'\t' '!/^#/ && $2 == "deployer" { print $1 }' "$CAT")
    [ -z "$missing" ] || { echo "catalogued phases with no splash line:$missing"; false; }
}

@test "every catalogued deployer phase carries the words shown on screen" {
    run awk -F'\t' '!/^#/ && $2 == "deployer" && $3 == "" { print $1 }' "$CAT"
    [ -z "$output" ]
}

@test "the installer/frontend halves are pinned by a Go test, not by hope" {
    grep -q 'func TestProgressScreenListsExactlyWhatThePipelineEmits' "$REPO_ROOT/app/steps_test.go"
    grep -q 'func TestEveryPipelineStepIsInTheCatalogue' "$REPO_ROOT/app/steps_test.go"
    # And the frontend list says where its contents come from.
    grep -q 'payload/steps.tsv' "$REPO_ROOT/app/frontend/src/screens/progress.js"
}
