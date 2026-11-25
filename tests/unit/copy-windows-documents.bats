#!/usr/bin/env bats
# copy-windows-documents.bats — the BitLocker Documents copy
# (payload/migration/wootc-copy-windows-documents) run for real as the
# invoking user: bytes and modification times must survive the copy.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    COPY="$REPO_ROOT/payload/migration/wootc-copy-windows-documents"
    SOURCE="$BATS_TEST_TMPDIR/windows/Users/alice/Documents"
    HOME_DIR="$BATS_TEST_TMPDIR/home"
    mkdir -p "$SOURCE/Projekte 2025/deep" "$HOME_DIR"
    printf 'quarterly report\n' > "$SOURCE/Projekte 2025/deep/report.txt"
    printf 'notes\n' > "$SOURCE/notes.txt"
    touch -d '2019-03-14 15:09:26 UTC' "$SOURCE/Projekte 2025/deep/report.txt"
    touch -d '2020-07-01 08:00:00 UTC' "$SOURCE/notes.txt"
}

@test "copied documents keep their Windows bytes and modification times" {
    [ "$(id -u)" != 0 ] || skip "runs as its non-root owner"
    run bash "$COPY" "$SOURCE" "$HOME_DIR" "$(id -un)"
    [ "$status" -eq 0 ]
    copy="$HOME_DIR/Documents/From Windows"
    cmp "$SOURCE/Projekte 2025/deep/report.txt" "$copy/Projekte 2025/deep/report.txt"
    [ "$(stat -c %Y "$copy/Projekte 2025/deep/report.txt")" = "$(date -d '2019-03-14 15:09:26 UTC' +%s)" ]
    [ "$(stat -c %Y "$copy/notes.txt")" = "$(date -d '2020-07-01 08:00:00 UTC' +%s)" ]
    [ "$(stat -c %a "$copy/notes.txt")" = 600 ]
}
