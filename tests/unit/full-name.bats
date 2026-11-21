#!/usr/bin/env bats
# shellcheck disable=SC2034  # the recipe tests set variables an eval'd heredoc reads
# full-name.bats — the Windows account full name becomes the Linux account's
# GECOS full name. The installer writes it to the vault (full_name), deploy.sh
# puts it in the fisherman recipe (user.fullname → useradd --comment), and
# wootc-go-native carries GECOS to the native disk. useradd refuses ':' and
# newlines and fisherman then stops the whole install, so these tests pin the
# sanitising, and that a quote or backslash cannot break the recipe JSON.
# The inputs mirror app/fullname_test.go (sanitizeFullName).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    GN="$REPO_ROOT/payload/migration/wootc-go-native"
    TMP="$BATS_TEST_TMPDIR"
}

# deploy_fn <function>... — the named deploy.sh functions, for eval.
deploy_fn() {
    local f
    for f in "$@"; do sed -n "/^$f() {/,/^}/p" "$DEPLOY"; done
}

@test "deploy.sh sanitises the full name with the installer's rule" {
    eval "$(deploy_fn sanitize_full_name)"
    [ "$(sanitize_full_name "Zoë O'Brien-Åberg a1b2c3")" = "Zoë O'Brien-Åberg a1b2c3" ]
    [ "$(sanitize_full_name $'Ann: "Bo\\b", Jr.\nSmith')" = 'Ann "Bo\b" Jr. Smith' ]
    [ "$(sanitize_full_name $'  山田 太郎\u3000José\u0301  ')" = $'山田 太郎 José\u0301' ]
    [ "$(sanitize_full_name $'A\x01l\x07i\x1bc\x7fe\u0085B\u009fob')" = 'Alice Bob' ]
    [ "$(sanitize_full_name $'Mary\t\tJane\r\nDoe')" = 'Mary Jane Doe' ]
    [ "$(sanitize_full_name 'Li , Wei : Chen')" = 'Li Wei Chen' ]
    [ "$(sanitize_full_name $' :,\n\t ')" = '' ]
    [ "$(sanitize_full_name '')" = '' ]
    [ "$(sanitize_full_name $'O\u00a0Neil\u2003Smith')" = 'O Neil Smith' ]
}

@test "deploy.sh caps the full name at 256 bytes on a character boundary" {
    eval "$(deploy_fn sanitize_full_name)"
    a255=$(printf 'a%.0s' $(seq 255))
    [ "$(sanitize_full_name "${a255}étail")" = "$a255" ]
    [ "$(sanitize_full_name "$a255 c")" = "$a255" ]
    long=$(sanitize_full_name "$(printf 'Åberg %.0s' $(seq 100))")
    [ "$(LC_ALL=C; printf '%s' "$long" | wc -c)" -le 256 ]
    [[ "$long" != *' ' ]]
    printf '%s' "$long" | iconv -f UTF-8 -t UTF-8 >/dev/null
}

@test "the vault's full name reaches the recipe user as valid JSON" {
    eval "$(deploy_fn sanitize_full_name vault_full_name recipe_user_json)"
    # The production lines: the vault ingest and the recipe's user member.
    grep -Fxq '        VAULT_FULL_NAME=$(vault_full_name "$VAULT_FILE")' "$DEPLOY"
    user_line=$(grep -E '^    USER_JSON=",\\"user\\": ' "$DEPLOY")
    [ "$(grep -cE '^    USER_JSON=",\\"user\\": ' "$DEPLOY")" -eq 1 ]
    heredoc=$(sed -n '/^cat > "\$RECIPE" << EOF$/,/^EOF$/p' "$DEPLOY" | sed '1d;$d')
    [ -n "$heredoc" ]
    LOOP_DEV=/dev/loop0 FILESYSTEM=xfs COMPOSEFS=0 GENERIC_IMAGE=0 BOOTLOADER=grub2
    LUKS_JSON='"encryption": { "type": "none" }' IMAGE=ghcr.io/ublue-os/bluefin:stable HOSTNAME=tunaos
    SETTINGS_JSON='' BUNDLE_JSON=''
    VAULT_USER=wootc VAULT_PASSWORD_HASH='$6$salt$hash'

    jq -n --arg n $'Zoë "Zed" O\'Brien-Åberg\\: a1b2c3, Room 1\n' \
        '{username: "wootc", password_hash: "$6$salt$hash", full_name: $n}' >"$TMP/vault.json"
    VAULT_FULL_NAME=$(vault_full_name "$TMP/vault.json")
    eval "$user_line"
    eval "cat <<EOF
$heredoc
EOF" >"$TMP/recipe.json"
    [ "$(jq -r '.user.fullname' "$TMP/recipe.json")" = 'Zoë "Zed" O'"'"'Brien-Åberg\ a1b2c3 Room 1' ]
    [ "$(jq -c '.user | {username, password, groups}' "$TMP/recipe.json")" = \
      '{"username":"wootc","password":"$6$salt$hash","groups":["wheel"]}' ]

    # The E2E seed survives byte for byte.
    jq -n '{full_name: "Zoë O'"'"'Brien-Åberg 0a1b2c"}' >"$TMP/vault.json"
    VAULT_FULL_NAME=$(vault_full_name "$TMP/vault.json")
    eval "$user_line"
    eval "cat <<EOF
$heredoc
EOF" >"$TMP/recipe.json"
    [ "$(jq -r '.user.fullname' "$TMP/recipe.json")" = "Zoë O'Brien-Åberg 0a1b2c" ]

    # A vault without a full name (older installer, or Windows has none):
    # no fullname member, and the recipe is still valid.
    printf '%s\n' '{"username":"wootc"}' >"$TMP/vault.json"
    VAULT_FULL_NAME=$(vault_full_name "$TMP/vault.json")
    [ -z "$VAULT_FULL_NAME" ]
    eval "$user_line"
    eval "cat <<EOF
$heredoc
EOF" >"$TMP/recipe.json"
    [ "$(jq -c '.user | has("fullname")' "$TMP/recipe.json")" = false ]
    [ "$(jq -r '.user.username' "$TMP/recipe.json")" = wootc ]
}

@test "Phase 3 applies the same rule to the GECOS full name" {
    for name in "Zoë O'Brien-Åberg a1b2c3" $'  山田 太郎\u3000José\u0301  ' \
                $'A\x01l\x07i\x1bc\x7fe\u0085B\u009fob' $'Mary\t\tJane\r\nDoe' \
                $'O\u00a0Neil\u2003Smith' 'Li : Chen'; do
        ours=$(eval "$(deploy_fn sanitize_full_name)"; sanitize_full_name "$name")
        theirs=$(bash -c 'source "$1"; phase2_user_json u "$2" ""' _ "$GN" "$name" | jq -r '.fullname // ""')
        [ "$ours" = "$theirs" ]
    done
}
