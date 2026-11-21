#!/usr/bin/env bats
# shellcheck disable=SC2034  # the recipe tests set variables an eval'd heredoc reads
# fisherman-recipe-contract.bats — the recipes wootc writes are accepted by
# the fisherman in the submodule, built from it.
#
# fisherman's strict recipe parser refuses a field it does not know
# (recipe_unknown_field) before any disk work. tuna-os/fisherman#476 removed
# every Windows feature from fisherman: the `slurp` and `slurpWallpapers`
# fields and the `fisherman scan` command. wootc does its own Windows data
# migration (the slurp module and the bridge); these tests prove that the
# Phase-1 deployer recipe and the Phase-3 native recipe, rendered from their
# real heredocs, carry no field the pinned fisherman does not know, and that
# wootc never calls the removed command.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    GN="$REPO_ROOT/payload/migration/wootc-go-native"
    TMP="$BATS_TEST_TMPDIR"
    [ -f "$REPO_ROOT/fisherman/fisherman/go.mod" ] \
        || skip "the fisherman submodule is not checked out (git submodule update --init fisherman)"
    command -v go >/dev/null || skip "go is not installed"
    : "${GOTMPDIR:=$HOME/.cache/wootc-gotmp}"; mkdir -p "$GOTMPDIR"; export GOTMPDIR
    # An exec-capable place for the binary (/tmp is noexec on some hosts).
    BIN="$HOME/.cache/wootc-bats-fisherman.$$"; mkdir -p "$BIN"
    (cd "$REPO_ROOT/fisherman/fisherman" && go build -o "$BIN/fisherman" ./cmd/fisherman/)
    FISHERMAN="$BIN/fisherman"
}

teardown() {
    [ -z "${BIN:-}" ] || rm -rf "$BIN"
}

# recipe_problems <recipe> — fisherman's problems with the recipe's content,
# one "field code" per line. The machine running the test is not the target:
# its disk and firmware problems (field "disk" and the unnamed ones) are left
# out, and nothing else is.
recipe_problems() {
    "$FISHERMAN" validate --json "$1" >"$TMP/validate.json" || true
    jq -e '.protocol_version == 1' "$TMP/validate.json" >/dev/null
    jq -r '.errors[] | select(.field != "disk" and .field != "") | "\(.field) \(.code)"' "$TMP/validate.json"
}

# deploy_fn <function>... — the named deploy.sh functions, for eval.
deploy_fn() {
    local f
    for f in "$@"; do sed -n "/^$f() {/,/^}/p" "$DEPLOY"; done
}

@test "the pinned fisherman refuses the removed slurp fields (the check below is not vacuous)" {
    printf '%s\n' '{"disk": "/dev/sdz", "image": "ghcr.io/projectbluefin/bluefin:stable", "hostname": "wootc",' \
        '"slurp": {"source": "/mnt/windows"}, "slurpWallpapers": true}' >"$TMP/recipe.json"
    run recipe_problems "$TMP/recipe.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"slurp recipe_unknown_field"* ]]
    [[ "$output" == *"slurpWallpapers recipe_unknown_field"* ]]
}

@test "the deployer recipe, with every optional member, has no field the pinned fisherman refuses" {
    eval "$(deploy_fn fisherman_settings_members locale_from_language_tag slurp_recipe_settings)"
    heredoc=$(sed -n '/^cat > "\$RECIPE" << EOF$/,/^EOF$/p' "$DEPLOY" | sed '1d;$d')
    [ -n "$heredoc" ]
    LOOP_DEV=/dev/loop0 FILESYSTEM=xfs COMPOSEFS=0 GENERIC_IMAGE=0 BOOTLOADER=grub2
    LUKS_JSON='"encryption": { "type": "luks-passphrase", "passphrase": "correct horse battery" }'
    IMAGE=ghcr.io/projectbluefin/bluefin:stable HOSTNAME=tunaos
    FLATPAKS_JSON='["org.mozilla.firefox"]'
    USER_JSON=',"user": { "username": "alex", "password": "$6$saltsalt$Ae0Ld4bIb0k2Q6bUp0sTQ0i7l1bS4q9dQ7g7mX9dDq1cX2e0l9n1lQ1g3zQ0r5Y6hF8vT4w2s1k0j9h8g7f6e5", "groups": ["wheel"] }'
    BUNDLE_JSON=''
    printf '%s\n' '{"timezone":"Europe/Berlin","language":"de-DE","keyboardLayout":"de"}' >"$TMP/slurp.json"
    SETTINGS_JSON=$(slurp_recipe_settings "$TMP/slurp.json")
    [ -n "$SETTINGS_JSON" ]
    eval "cat <<EOF
$heredoc
EOF" >"$TMP/recipe.json"
    jq -e '.encryption.type == "luks-passphrase" and .user.username == "alex" and .keyboard.layout == "de"' "$TMP/recipe.json"
    run recipe_problems "$TMP/recipe.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the native recipe, with the account and settings, has no field the pinned fisherman refuses" {
    ETC="$TMP/etc"; mkdir -p "$ETC"
    echo "wootc-test" >"$ETC/hostname"
    ln -sfn ../usr/share/zoneinfo/Europe/Paris "$ETC/localtime"
    printf 'LANG="fr_FR.UTF-8"\n' >"$ETC/locale.conf"
    printf 'XKBLAYOUT=fr\nXKBVARIANT=latin9\nXKBMODEL=pc105\n' >"$ETC/vconsole.conf"
    heredoc=$(sed -n '/^    cat > "\$recipe" <<EOF$/,/^EOF$/p' "$GN" | sed '1d;$d')
    [ -n "$heredoc" ]
    run env WOOTC_GN_ETC="$ETC" HEREDOC="$heredoc" bash -c 'source "$1"
        target=/dev/sdb filesystem=xfs img=ghcr.io/projectbluefin/bluefin:stable
        guser=alex gfull="Alex Doe" ghash="\$6\$saltsalt\$Ae0Ld4bIb0k2Q6bUp0sTQ0i7l1bS4q9dQ7g7mX9dDq1cX2e0l9n1lQ1g3zQ0r5Y6hF8vT4w2s1k0j9h8g7f6e5"
        guserjson=",
  \"user\": {
    \"username\": \"$guser\",
    \"fullname\": \"$gfull\",
    \"password\": \"$ghash\",
    \"groups\": [\"wheel\"]
  }"
        ghost=$(phase2_hostname); gsettings=$(phase2_recipe_settings)
        gflatpakjson="[\"org.mozilla.firefox\"]"
        eval "cat <<EOF
$HEREDOC
EOF"' _ "$GN"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" >"$TMP/recipe.json"
    jq -e '.user.username == "alex" and .copyNetworkProfiles == true and .locale == "fr_FR.UTF-8"' "$TMP/recipe.json"
    run recipe_problems "$TMP/recipe.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "wootc never calls the fisherman commands #476 removed" {
    # wootc's own tools have scan subcommands (wootc-identity scan); only a
    # fisherman invocation counts: `fisherman scan`, ("fisherman", "scan").
    run grep -rnE "fisherman[\"']?,?[[:space:]]*[\"']?scan\\b" "$REPO_ROOT/payload" "$REPO_ROOT/app" \
        "$REPO_ROOT/tests/e2e"
    [ "$status" -eq 1 ]
    # The command really is gone from the pinned fisherman.
    run "$FISHERMAN" scan
    [ "$status" -eq 2 ]
    [[ "$output" == *'unknown command "scan"'* ]]
}
