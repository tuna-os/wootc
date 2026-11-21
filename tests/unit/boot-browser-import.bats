#!/usr/bin/env bats
# The Phase-2 boot bridge runs the browser import for each user until one
# attempt completes (payload/migration/wootc-mount-user-dirs). Before, the
# import was reachable only from the CLI for the internal Windows disk, so no
# user's bookmarks ever arrived.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    MOUNT="$ROOT/payload/migration/wootc-mount-user-dirs"
    STANZA="$BATS_TEST_TMPDIR/stanza.sh"
    sed -n '/^        # Browser bookmarks\/history\/profile/,/^        fi$/p' "$MOUNT" > "$STANZA"
    grep -q 'wootc-import-browser "$winuser" "$uname"' "$STANZA"
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/home/alice/.config/wootc"
    CALLS="$BATS_TEST_TMPDIR/calls"
    printf '#!/bin/sh\necho "$@" >> "%s"\n' "$CALLS" > "$BATS_TEST_TMPDIR/bin/wootc-import-browser"
    chmod +x "$BATS_TEST_TMPDIR/bin/wootc-import-browser"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH" CALLS STANZA
    export userhome="$BATS_TEST_TMPDIR/home/alice/" uname=alice winuser=Alice
}

run_stanza() { # <chooser rc>
    CHOOSER_RC="$1" bash -c 'log() { echo "$*"; }; sel_on() { return "$CHOOSER_RC"; }; source "$STANZA"'
}

@test "the boot bridge imports browsers when no attempt completed yet" {
    run run_stanza 0
    [ "$status" -eq 0 ]
    [ "$(cat "$CALLS")" = "Alice alice" ]
}

@test "a failed attempt is retried on the next boot" {
    printf '{"state":"failed"}\n' > "$userhome.config/wootc/bridge-browser.json"
    run run_stanza 0
    [ "$(cat "$CALLS")" = "Alice alice" ]
}

@test "a completed import, or nothing to import, is not repeated" {
    for state in native unchanged; do
        printf '{"state":"%s"}\n' "$state" > "$userhome.config/wootc/bridge-browser.json"
        run run_stanza 0
        [ "$status" -eq 0 ]
        [ ! -e "$CALLS" ]
    done
}

@test "browsers turned off in the chooser are never imported" {
    run run_stanza 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"browsers: skipped for alice"* ]]
    [ ! -e "$CALLS" ]
}
