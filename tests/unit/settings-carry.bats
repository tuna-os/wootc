#!/usr/bin/env bats
# shellcheck disable=SC2034  # the recipe tests set variables an eval'd heredoc reads
# settings-carry.bats — the Windows time zone, language and keyboard reach the
# installed system through the fisherman recipe (deploy.sh), and Phase 3
# carries the Phase-2 system's hostname, settings and Wi-Fi profiles to the
# native disk (wootc-go-native). fisherman writes the files; these tests pin
# what the recipes ask for, and that no value fisherman would refuse (which
# stops the whole install) gets into a recipe.

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

@test "deploy.sh and wootc-go-native share one fisherman_settings_members" {
    ours=$(sed -n '/^fisherman_settings_members() {/,/^}/p' "$DEPLOY")
    theirs=$(sed -n '/^fisherman_settings_members() {/,/^}/p' "$GN")
    [ -n "$ours" ]
    [ "$ours" = "$theirs" ]
}

@test "Windows language tags become glibc locales" {
    eval "$(deploy_fn locale_from_language_tag)"
    [ "$(locale_from_language_tag en-US)" = en_US.UTF-8 ]
    [ "$(locale_from_language_tag de-DE)" = de_DE.UTF-8 ]
    [ "$(locale_from_language_tag pt-BR)" = pt_BR.UTF-8 ]
    [ "$(locale_from_language_tag ja)" = ja_JP.UTF-8 ]
    [ "$(locale_from_language_tag zh-Hant-TW)" = zh_TW.UTF-8 ]
    [ "$(locale_from_language_tag zh-Hant)" = zh_TW.UTF-8 ]
    [ "$(locale_from_language_tag sr-Latn-RS)" = sr_RS.UTF-8 ]
    [ -z "$(locale_from_language_tag xx)" ]
    [ -z "$(locale_from_language_tag "")" ]
    [ -z "$(locale_from_language_tag '1234-US')" ]
}

@test "slurp.json time zone, language and keyboard become recipe members" {
    eval "$(deploy_fn fisherman_settings_members locale_from_language_tag slurp_recipe_settings)"
    printf '%s\n' '{"timezone":"Europe/Berlin","language":"de-DE","keyboardLayout":"de","wallpaper":"wallpaper.jpg"}' >"$TMP/slurp.json"
    run slurp_recipe_settings "$TMP/slurp.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' '"timezone": "Europe/Berlin",' '"locale": "de_DE.UTF-8",' '"keyboard": {"layout": "de"},')" ]
    # No slurp.json: the image's settings stay.
    run slurp_recipe_settings "$TMP/absent.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a value fisherman would refuse is left out, not put in the recipe" {
    eval "$(deploy_fn fisherman_settings_members)"
    members=$(fisherman_settings_members 'Europe/Berlin"; rm' 'de_DE.UTF-8' 'de nodeadkeys' '' '' 2>"$TMP/err")
    [ "$members" = '"locale": "de_DE.UTF-8",' ]
    grep -q 'time zone .* is not an IANA name; left out' "$TMP/err"
    grep -q 'keyboard layout .* is not an XKB layout; keyboard left out' "$TMP/err"
    members=$(fisherman_settings_members '' 'en_US.utf8' 'us,ru' 'bad variant' 'pc105' 2>"$TMP/err")
    [ "$members" = "$(printf '%s\n' '"locale": "en_US.utf8",' '"keyboard": {"layout": "us,ru", "model": "pc105"},')" ]
    grep -q 'variant left out' "$TMP/err"
    members=$(fisherman_settings_members 'UTC' 'C.UTF-8' 'de' 'nodeadkeys' '' 2>"$TMP/err")
    [ "$members" = "$(printf '%s\n' '"timezone": "UTC",' '"locale": "C.UTF-8",' '"keyboard": {"layout": "de", "variant": "nodeadkeys"},')" ]
    [ ! -s "$TMP/err" ]
}

@test "the deployer recipe is valid JSON with the Windows settings, and without them" {
    eval "$(deploy_fn fisherman_settings_members locale_from_language_tag slurp_recipe_settings)"
    heredoc=$(sed -n '/^cat > "\$RECIPE" << EOF$/,/^EOF$/p' "$DEPLOY" | sed '1d;$d')
    [ -n "$heredoc" ]
    LOOP_DEV=/dev/loop0 FILESYSTEM=xfs COMPOSEFS=0 GENERIC_IMAGE=0 BOOTLOADER=grub2
    LUKS_JSON='"encryption": { "type": "none" }' IMAGE=ghcr.io/ublue-os/bluefin:stable HOSTNAME=tunaos
    FLATPAKS_JSON='[]' USER_JSON='' BUNDLE_JSON=''
    printf '%s\n' '{"timezone":"America/New_York","language":"en-GB","keyboardLayout":"gb"}' >"$TMP/slurp.json"
    SETTINGS_JSON=$(slurp_recipe_settings "$TMP/slurp.json")
    eval "cat <<EOF
$heredoc
EOF" >"$TMP/recipe.json"
    [ "$(jq -c '{timezone, locale, keyboard, hostname}' "$TMP/recipe.json")" = \
      '{"timezone":"America/New_York","locale":"en_GB.UTF-8","keyboard":{"layout":"gb"},"hostname":"tunaos"}' ]
    SETTINGS_JSON=""
    eval "cat <<EOF
$heredoc
EOF" >"$TMP/recipe.json"
    [ "$(jq -c '[has("timezone"), has("locale"), has("keyboard")]' "$TMP/recipe.json")" = '[false,false,false]' ]
    # The old /usr zoneinfo probe is gone: under composefs it never saw /usr.
    [ "$(grep -c 'usr/share/zoneinfo/\$SLURP_TZ' "$DEPLOY")" -eq 0 ]
    grep -Fq 'SETTINGS_JSON=$(slurp_recipe_settings /mnt/ntfs/wootc/install/slurp/slurp.json' "$DEPLOY"
}

# phase2_etc — a fixture /etc for wootc-go-native.
phase2_etc() {
    ETC="$TMP/etc"; mkdir -p "$ETC"
    echo "wootc-test" >"$ETC/hostname"
    ln -sfn ../usr/share/zoneinfo/Europe/Paris "$ETC/localtime"
    printf 'LANG="fr_FR.UTF-8"\nLC_TIME=en_GB.UTF-8\n' >"$ETC/locale.conf"
    printf 'KEYMAP=fr-latin9\nXKBLAYOUT=fr\nXKBVARIANT=latin9\nXKBMODEL=pc105\n' >"$ETC/vconsole.conf"
}

@test "Phase 3 reads the Phase-2 hostname, time zone, language and keyboard" {
    phase2_etc
    run env WOOTC_GN_ETC="$ETC" bash -c 'source "$1"; phase2_hostname; phase2_recipe_settings' _ "$GN"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' wootc-test '"timezone": "Europe/Paris",' '"locale": "fr_FR.UTF-8",' '"keyboard": {"layout": "fr", "variant": "latin9", "model": "pc105"},')" ]
    # A Phase-2 system without these files: the image's settings, hostname wootc.
    run env WOOTC_GN_ETC="$TMP/empty" bash -c 'source "$1"; phase2_hostname; phase2_recipe_settings' _ "$GN"
    [ "$status" -eq 0 ]
    [ "$output" = wootc ]
    echo "bad_host!" >"$ETC/hostname"
    run env WOOTC_GN_ETC="$ETC" bash -c 'source "$1"; phase2_hostname 2>/dev/null' _ "$GN"
    [ "$output" = wootc ]
}

@test "the native recipe is valid JSON and carries hostname, settings and Wi-Fi profiles" {
    phase2_etc
    heredoc=$(sed -n '/^    cat > "\$recipe" <<EOF$/,/^EOF$/p' "$GN" | sed '1d;$d')
    [ -n "$heredoc" ]
    run env WOOTC_GN_ETC="$ETC" HEREDOC="$heredoc" bash -c 'source "$1"
        target=/dev/sdb filesystem=xfs img=ghcr.io/ublue-os/bluefin:stable guserjson=""
        ghost=$(phase2_hostname); gsettings=$(phase2_recipe_settings)
        gflatpakjson="[]"
        eval "cat <<EOF
$HEREDOC
EOF"' _ "$GN"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(jq -c '{hostname, timezone, locale, keyboard, copyNetworkProfiles}' <<<"$output")" = \
      '{"hostname":"wootc-test","timezone":"Europe/Paris","locale":"fr_FR.UTF-8","keyboard":{"layout":"fr","variant":"latin9","model":"pc105"},"copyNetworkProfiles":true}' ]
    [ "$(grep -c '"hostname": "wootc",' "$GN")" -eq 0 ]
}
