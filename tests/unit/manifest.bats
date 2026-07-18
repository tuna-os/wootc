#!/usr/bin/env bats
# manifest.bats — migration discovery catalog (wootc-manifest), the data behind
# the "what should we bring over?" opt-out GUI (#7). Read-only: scans a fixture
# Windows volume via WOOTC_HOST and asserts the catalog + default-on semantics.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    MAN="$REPO_ROOT/payload/migration/wootc-manifest"
    export WOOTC_HOST="$BATS_TEST_TMPDIR/host"
    U="$WOOTC_HOST/Users/alice"
    mkdir -p "$U/Documents" "$U/Pictures" "$WOOTC_HOST/Users/Public"
    echo a >"$U/Documents/a.txt"; echo b >"$U/Documents/b.txt"; echo c >"$U/Pictures/c.jpg"
    mkdir -p "$U/AppData/Roaming/Mozilla/Firefox"; echo '[Install0]' >"$U/AppData/Roaming/Mozilla/Firefox/profiles.ini"
    mkdir -p "$WOOTC_HOST/Program Files (x86)/Steam/steamapps"; echo v >"$WOOTC_HOST/Program Files (x86)/Steam/steamapps/libraryfolders.vdf"
    mkdir -p "$WOOTC_HOST/wootc/install/wifi"; echo '<x/>' >"$WOOTC_HOST/wootc/install/wifi/Home.xml"; echo '<x/>' >"$WOOTC_HOST/wootc/install/wifi/Cafe.xml"
    mkdir -p "$U/AppData/Local/lxss/rootfs"
}

cat_field() {  # $1=category id  $2=jq-ish python path within that category
    python3 -c "import sys,json; d=json.load(sys.stdin); c={x['id']:x for x in d['users'][0]['categories']}; print(c['$1']$2)"
}

@test "scan discovers present categories and defaults them ON" {
    run bash -c "'$MAN' scan alice"
    [ "$status" -eq 0 ]
    for c in files browsers games wifi wsl; do
        echo "$output" | cat_field "$c" "['present']" | grep -q True
        echo "$output" | cat_field "$c" "['defaultOn']" | grep -q True
    done
}

@test "absent category is present=false and defaultOn=false" {
    run bash -c "'$MAN' scan alice"
    echo "$output" | cat_field office "['present']" | grep -q False
    echo "$output" | cat_field office "['defaultOn']" | grep -q False
}

@test "files category lists the actual folders found" {
    run bash -c "'$MAN' scan alice"
    ids=$(echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); c={x['id']:x for x in d['users'][0]['categories']}; print(sorted(i['id'] for i in c['files']['items']))")
    [[ "$ids" == "['Documents', 'Pictures']" ]]
}

@test "wifi item reports the number of exported profiles" {
    run bash -c "'$MAN' scan alice"
    echo "$output" | cat_field wifi "['items'][0]['detail']" | grep -q "2 profile"
}

@test "the Public profile is ignored by --all" {
    run bash -c "'$MAN' scan --all"
    users=$(echo "$output" | python3 -c "import sys,json; print([u['winUser'] for u in json.load(sys.stdin)['users']])")
    [[ "$users" == "['alice']" ]]
}

@test "scan with no discoverable data is a clean empty catalog (no crash)" {
    export WOOTC_HOST="$BATS_TEST_TMPDIR/empty"; mkdir -p "$WOOTC_HOST"
    run bash -c "'$MAN' scan bob"
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); assert all(not c['present'] for c in d['users'][0]['categories'])"
}
