#!/usr/bin/env bats
setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CAT="$REPO_ROOT/payload/steps.tsv"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
}
@test "all generated step IDs, owners and labels are current" {
    run python3 "$REPO_ROOT/packaging/generate-steps.py" --check
    [ "$status" -eq 0 ]
}
@test "every phase the deployer announces is catalogued with the correct owner" {
    source "$REPO_ROOT/payload/steps.sh"
    local id missing=""
    while read -r id; do
        [[ $(wootc_step_owner "$id") == deployer ]] || missing="$missing $id"
    done < <(grep -oE '^\s*phase "[a-z0-9-]+"' "$DEPLOY" | grep -oE '"[a-z0-9-]+"' | tr -d '"' | sort -u)
    [ -z "$missing" ] || { echo "uncatalogued deployer phases:$missing"; false; }
}
@test "real splash, firstboot and harness consumers reject label and stale-output mutations" {
    run python3 -m unittest discover -s "$REPO_ROOT/tests/unit" -p test_step_catalogue.py -v
    [ "$status" -eq 0 ]
}
