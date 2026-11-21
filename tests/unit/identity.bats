#!/usr/bin/env bats
# identity.bats — non-secret identity prefill + copy (wootc-identity, issue #8).
# Passwords are never migratable; username/full-name/avatar/locale are. Runs on
# the host against fixture Windows volumes (WOOTC_HOST) and a fake home +
# AccountsService dir (WOOTC_HOME / WOOTC_AS_DIR) — no real accounts touched.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    ID="$REPO_ROOT/payload/migration/wootc-identity"
    export WOOTC_HOST="$BATS_TEST_TMPDIR/host"
    AP="$WOOTC_HOST/Users/John Smith/AppData/Roaming/Microsoft/Windows/AccountPictures"
    mkdir -p "$AP" "$WOOTC_HOST/wootc/install/slurp"
    printf 'PNGDATA' >"$AP/tile.png"
    printf '{"fullName":"John Smith","email":"john.smith@outlook.com","locale":"en-US","keyboardLayout":"us","timezone":"America/New_York"}\n' \
        >"$WOOTC_HOST/wootc/install/slurp/slurp.json"
}

@test "scan reports a Linux-safe username and the full name/email/locale" {
    run bash -c "'$ID' scan 'John Smith'"
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["username"]=="johnsmith" and d["fullName"]=="John Smith" and d["email"]=="john.smith@outlook.com" and d["locale"]=="en-US", d'
}

@test "scan always reports the password as NOT migratable" {
    run bash -c "'$ID' scan 'John Smith'"
    echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["password"]["migratable"] is False, d'
}

@test "scan finds the account picture" {
    run bash -c "'$ID' scan 'John Smith'"
    echo "$output" | python3 -c 'import sys,json,os; d=json.load(sys.stdin); assert d["avatar"] and os.path.basename(d["avatar"])=="tile.png", d'
}

@test "apply copies the account picture to ~/.face and AccountsService" {
    export WOOTC_HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$WOOTC_HOME"
    export WOOTC_AS_DIR="$BATS_TEST_TMPDIR/as"
    run bash -c "'$ID' apply 'John Smith' johnsmith"
    [ "$status" -eq 0 ]
    [ -f "$WOOTC_HOME/.face" ]
    [ "$(cat "$WOOTC_HOME/.face")" = "PNGDATA" ]
    [ -f "$WOOTC_AS_DIR/icons/johnsmith" ]
    grep -q "RealName=John Smith" "$WOOTC_AS_DIR/users/johnsmith"
    grep -q "Icon=" "$WOOTC_AS_DIR/users/johnsmith"
    echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert "face" in d["applied"] and "accountsservice" in d["applied"], d'
}

@test "apply with no account picture still succeeds (name only, no crash)" {
    rm -rf "$WOOTC_HOST/Users/John Smith/AppData"
    export WOOTC_HOME="$BATS_TEST_TMPDIR/home2"; mkdir -p "$WOOTC_HOME"
    export WOOTC_AS_DIR="$BATS_TEST_TMPDIR/as2"
    run bash -c "'$ID' apply 'John Smith' johnsmith"
    [ "$status" -eq 0 ]
    [ ! -f "$WOOTC_HOME/.face" ]
}

# gecos_stubs <GECOS> — getent reports a johnsmith account with that GECOS
# field (what the deployer's useradd --comment left), and chfn records its
# arguments in $CHFN instead of changing anything. The stubs must execute: a
# noexec tmpdir would leave the real tools in charge and the "chfn was not
# called" assertions passing vacuously.
gecos_stubs() {
    STUBS="$BATS_TEST_TMPDIR/stubs"; mkdir -p "$STUBS"
    printf '#!/bin/bash\ntrue\n' >"$STUBS/.probe"; chmod +x "$STUBS/.probe"
    if ! "$STUBS/.probe" 2>/dev/null; then
        STUBS="$HOME/.cache/wootc-bats-identity.$$"; mkdir -p "$STUBS"
        printf '#!/bin/bash\ntrue\n' >"$STUBS/.probe"; chmod +x "$STUBS/.probe"
        "$STUBS/.probe"
    fi
    CHFN="$BATS_TEST_TMPDIR/chfn.calls"
    printf '#!/bin/bash\n[ "$2" = johnsmith ] || exit 2\nprintf "%%s\\n" "johnsmith:x:1000:1000:%s:/home/johnsmith:/bin/bash"\n' "$1" >"$STUBS/getent"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$CHFN" >"$STUBS/chfn"
    chmod +x "$STUBS/getent" "$STUBS/chfn"
    export PATH="$STUBS:$PATH"
}

@test "apply keeps the vault's GECOS full name when slurp.json has none" {
    # Windows-Style Mode off: no fullName in slurp.json. The account already
    # carries the Windows full name from the vault; apply must not blank it,
    # and the login screen shows it.
    printf '{"locale":"en-US"}\n' >"$WOOTC_HOST/wootc/install/slurp/slurp.json"
    gecos_stubs "Zoë O'Brien-Åberg 0a1b2c,,,"
    export WOOTC_HOME="$BATS_TEST_TMPDIR/home3"; mkdir -p "$WOOTC_HOME"
    export WOOTC_AS_DIR="$BATS_TEST_TMPDIR/as3"
    run "$ID" apply 'John Smith' johnsmith
    [ "$status" -eq 0 ]
    [ ! -e "$CHFN" ]
    grep -Fxq "RealName=Zoë O'Brien-Åberg 0a1b2c" "$WOOTC_AS_DIR/users/johnsmith"
    echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["fullName"]=="Zoë O'"'"'Brien-Åberg 0a1b2c" and "fullname" not in d["applied"], d'
}

@test "apply leaves an equal GECOS name alone and still applies a different slurp name" {
    gecos_stubs "John Smith"
    export WOOTC_HOME="$BATS_TEST_TMPDIR/home4"; mkdir -p "$WOOTC_HOME"
    export WOOTC_AS_DIR="$BATS_TEST_TMPDIR/as4"
    run "$ID" apply 'John Smith' johnsmith
    [ "$status" -eq 0 ]
    [ ! -e "$CHFN" ]
    gecos_stubs "Someone Else"
    run "$ID" apply 'John Smith' johnsmith
    [ "$status" -eq 0 ]
    [ "$(cat "$CHFN")" = "-f John Smith johnsmith" ]
    grep -Fxq "RealName=John Smith" "$WOOTC_AS_DIR/users/johnsmith"
}

teardown() {
    [[ "${STUBS:-}" == "$HOME/.cache/"* ]] && rm -rf "$STUBS"
    return 0
}
