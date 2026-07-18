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
