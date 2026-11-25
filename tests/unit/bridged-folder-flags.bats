#!/usr/bin/env bats
# Probe 44889931801: the user could read the bridged Documents but got EACCES
# writing into it. Windows flags shell folders FILE_ATTRIBUTE_READONLY (a
# desktop.ini marker Windows does not enforce on directories) and the kernel
# ntfs3 driver turns it into a mode without write bits (fs/ntfs3/inode.c,
# ntfs_read_mft). The bridge clears the flag on folders while Linux runs,
# records the originals on the Windows volume first, and puts them back at
# shutdown and at the next boot.
#
# The real wootc-mount-user-dirs and wootc-umount-user-dirs run here, with
# mount, mountpoint, umount and getent stubbed. A user xattr stands in for
# ntfs3's system.ntfs_attrib.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    T="$BATS_TEST_TMPDIR"
    # PATH stubs must actually execute: /tmp is noexec on some dev hosts.
    STUBDIR="$T/bin"; mkdir -p "$STUBDIR"
    printf '#!/bin/sh\ntrue\n' >"$STUBDIR/.probe"; chmod +x "$STUBDIR/.probe"
    if ! "$STUBDIR/.probe" 2>/dev/null; then
        STUBDIR="$HOME/.cache/wootc-bats-folder-flags.$$"; mkdir -p "$STUBDIR"
        printf '#!/bin/sh\ntrue\n' >"$STUBDIR/.probe"; chmod +x "$STUBDIR/.probe"
        "$STUBDIR/.probe" 2>/dev/null || { echo "FATAL: cannot create an executable stub" >&2; return 1; }
    fi
    ME=$(id -un)
    HOMEDIR="$T/home"
    export CALLS="$T/calls" WOOTC_NTFS_ATTRIB_XATTR=user.ntfs_attrib
    export WOOTC_HOST="$T/private/wootc-host" ME HOMEDIR
    printf '#!/bin/bash\nprintf "mount %%s\\n" "$*" >> "$CALLS"\n' >"$STUBDIR/mount"
    printf '#!/bin/bash\nprintf "umount %%s\\n" "$*" >> "$CALLS"\n' >"$STUBDIR/umount"
    printf '#!/bin/bash\n[[ "${*: -1}" == */wootc-host ]]\n' >"$STUBDIR/mountpoint"
    # Only this account's passwd entry, with its home in the test tree.
    printf '#!/bin/bash\n[[ "$1 $2" == "passwd $ME" ]] && echo "$ME:x:$(id -u):$(id -g)::$HOMEDIR:/bin/bash"\n' >"$STUBDIR/getent"
    ln -s "$ROOT/payload/migration/wootc-folder-flags" "$STUBDIR/wootc-folder-flags"
    chmod +x "$STUBDIR/mount" "$STUBDIR/umount" "$STUBDIR/mountpoint" "$STUBDIR/getent"
    export PATH="$STUBDIR:$PATH"

    D="$WOOTC_HOST/Users/$ME/Documents"
    P="$WOOTC_HOST/Users/$ME/Pictures"
    STATE="$WOOTC_HOST/wootc/folder-flags.json"
    mkdir -p "$WOOTC_HOST/wootc" "$D/Custom" "$D/Plain" "$P" "$HOMEDIR"
    echo hi >"$D/locked.txt"
    # DIRECTORY|ARCHIVE|READONLY, as Windows leaves its shell folders.
    ntfs_attrib "$D" 0x10000021
    ntfs_attrib "$D/Custom" 0x10000021
    ntfs_attrib "$D/Plain" 0x10000020
    ntfs_attrib "$D/locked.txt" 0x00000021
    ntfs_attrib "$P" 0x10000021
}

teardown() {
    chmod -R u+rwx "$T" 2>/dev/null || true
    [[ "$STUBDIR" == "$HOME"/.cache/* ]] && rm -rf "$STUBDIR"
    return 0
}

ntfs_attrib() {
    python3 -c 'import os, struct, sys
name = os.environ["WOOTC_NTFS_ATTRIB_XATTR"]
if len(sys.argv) > 2:
    os.setxattr(sys.argv[1], name, struct.pack("<I", int(sys.argv[2], 16)))
else:
    print("0x%08x" % struct.unpack("<I", os.getxattr(sys.argv[1], name)))' "$@"
}

# The recorded folders, one "path attributes" per line.
recorded() {
    python3 -c 'import json, sys
for e in json.load(open(sys.argv[1]))["folders"]:
    print(e["path"], e["attributes"])' "$STATE"
}

boot() { run bash "$ROOT/payload/migration/wootc-mount-user-dirs"; }
shutdown() { run bash "$ROOT/payload/migration/wootc-umount-user-dirs"; }

need_real_account() {
    [ "$(id -u)" -ge 1000 ] || skip "the bridge only binds for accounts with UID >= 1000"
}

@test "the boot records the original flags, then clears READONLY on bridged folders but never on files" {
    need_real_account
    boot
    [ "$status" -eq 0 ]
    [ "$(ntfs_attrib "$D")" = 0x10000020 ]
    [ "$(ntfs_attrib "$D/Custom")" = 0x10000020 ]
    [ "$(ntfs_attrib "$D/Plain")" = 0x10000020 ]
    [ "$(ntfs_attrib "$P")" = 0x10000020 ]
    # Windows enforces READONLY on files: a read-only file stays read-only.
    [ "$(ntfs_attrib "$D/locked.txt")" = 0x00000021 ]
    [ "$(recorded)" = "Users/$ME/Documents 0x10000021
Users/$ME/Documents/Custom 0x10000021
Users/$ME/Pictures 0x10000021" ]
    [[ "$output" == *"files/Documents: cleared the Windows read-only flag on 2 folder(s)"* ]]
    grep -qxF "mount --bind $D $HOMEDIR/Documents" "$CALLS"
    grep -qxF "mount --bind $P $HOMEDIR/Pictures" "$CALLS"
}

@test "shutdown puts every recorded flag back and removes the record" {
    need_real_account
    boot
    [ "$status" -eq 0 ]
    [ -f "$STATE" ]
    shutdown
    [ "$status" -eq 0 ]
    [ "$(ntfs_attrib "$D")" = 0x10000021 ]
    [ "$(ntfs_attrib "$D/Custom")" = 0x10000021 ]
    [ "$(ntfs_attrib "$D/Plain")" = 0x10000020 ]
    [ "$(ntfs_attrib "$P")" = 0x10000021 ]
    [ "$(ntfs_attrib "$D/locked.txt")" = 0x00000021 ]
    [ ! -e "$STATE" ]
}

@test "a record left by a boot without shutdown is restored first, then the folders are cleared again" {
    need_real_account
    boot
    [ "$status" -eq 0 ]
    # No shutdown: the machine lost power. Pictures was converted to native
    # storage meanwhile, so the next boot no longer bridges it.
    mkdir -p "$HOMEDIR/.config/wootc"
    touch "$HOMEDIR/.config/wootc/converted-Pictures"
    boot
    [ "$status" -eq 0 ]
    [[ "$output" == *"restored the Windows read-only flag on 3 folder(s)"* ]]
    # Restored and no longer bridged: Windows has its flag back for good.
    [ "$(ntfs_attrib "$P")" = 0x10000021 ]
    # Restored, then cleared again for this session, with the original kept.
    [ "$(ntfs_attrib "$D")" = 0x10000020 ]
    [ "$(ntfs_attrib "$D/Custom")" = 0x10000020 ]
    [ "$(recorded)" = "Users/$ME/Documents 0x10000021
Users/$ME/Documents/Custom 0x10000021" ]
}

@test "nothing is cleared when the record cannot be written, and the folder is still bound" {
    need_real_account
    [ "$(id -u)" -ne 0 ] || skip "root writes through a read-only directory"
    chmod 0555 "$WOOTC_HOST/wootc"
    boot
    [ "$status" -eq 0 ]
    [ "$(ntfs_attrib "$D")" = 0x10000021 ]
    [ "$(ntfs_attrib "$D/Custom")" = 0x10000021 ]
    [ ! -e "$STATE" ]
    [[ "$output" == *"nothing cleared"* ]]
    grep -qxF "mount --bind $D $HOMEDIR/Documents" "$CALLS"
}

@test "restore puts back only READONLY and keeps other attribute changes made meanwhile" {
    run "$ROOT/payload/migration/wootc-folder-flags" clear "$WOOTC_HOST" "$D"
    [ "$status" -eq 0 ]
    [ "$output" = 2 ]
    ntfs_attrib "$D" 0x10000022   # the user hid the folder while Linux ran
    run "$ROOT/payload/migration/wootc-folder-flags" restore "$WOOTC_HOST"
    [ "$status" -eq 0 ]
    [ "$(ntfs_attrib "$D")" = 0x10000023 ]
    [ "$(ntfs_attrib "$D/Custom")" = 0x10000021 ]
    [ ! -e "$STATE" ]
}

@test "folders on the read-only unlocked BitLocker volume keep their Windows flags" {
    BITLOCKER_PROFILES="$T/bitlk"
    B="$BITLOCKER_PROFILES/Users/fixture/Pictures"
    mkdir -p "$B"
    ntfs_attrib "$B" 0x10000021
    HOST="$WOOTC_HOST"
    eval "$(sed -n '/^safe_folder_source()/,/^}/p' "$ROOT/payload/migration/wootc-mount-user-dirs")"
    eval "$(sed -n '/^folder_flags()/,/^}/p' "$ROOT/payload/migration/wootc-mount-user-dirs")"
    eval "$(sed -n '/^bind_profile()/,/^}/p' "$ROOT/payload/migration/wootc-mount-user-dirs")"
    sel_on() { return 0; }
    resolved_folder() { return 0; }
    add_host_bookmark() { :; }
    log() { echo "$*"; }
    warn() { echo "$*" >&2; }
    FOLDERS=(Pictures)
    bound=0
    run bind_profile "$BITLOCKER_PROFILES/Users/fixture/" "$ME" "$HOMEDIR"
    [ "$status" -eq 0 ]
    [ "$(ntfs_attrib "$B")" = 0x10000021 ]
    [ ! -e "$STATE" ]
    grep -qxF "mount --bind $B $HOMEDIR/Pictures" "$CALLS"
}
