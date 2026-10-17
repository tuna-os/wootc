#!/usr/bin/env bats
# bitlocker-key-lifecycle.bats — the recovery key outlives every boot that
# still needs it, and nothing else (#279).
#
# The bridge does not copy the Windows folders once. On every Phase-2 boot it
# unlocks the encrypted C: with the recovery key and bind-mounts the folders
# live. wootc-umount-user-dirs, the ExecStop of wootc-passthrough.service,
# used to shred the key on every shutdown, so the SECOND boot logged "no
# BitLocker recovery key file found" and every unconverted folder vanished.
#
# The contract these tests pin:
#   - the deployer moves the key from NTFS into the installed root
#     (/etc/wootc/bitlocker-key, 0600) and shreds the NTFS copy only after the
#     move is verified;
#   - the bridge reads the /etc copy first, the NTFS copy only as a fallback
#     for deployments made before the move;
#   - shutdown never deletes the key;
#   - wootc-convert-dir shreds it once nothing is bridged from C: any more.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    MOUNT="$REPO_ROOT/payload/migration/wootc-mount-user-dirs"
    UMOUNT="$REPO_ROOT/payload/migration/wootc-umount-user-dirs"
    CONVERT="$REPO_ROOT/payload/migration/wootc-convert-dir"
    T="$BATS_TEST_TMPDIR"

    # PATH stubs must actually execute: /tmp is noexec on some dev hosts, and
    # a stub that cannot run makes every assertion below vacuous.
    STUBDIR="$T/bin"; mkdir -p "$STUBDIR"
    printf '#!/bin/sh\ntrue\n' >"$STUBDIR/.probe"; chmod +x "$STUBDIR/.probe"
    if ! "$STUBDIR/.probe" 2>/dev/null; then
        STUBDIR="$HOME/.cache/wootc-bats-bitlk.$$"; mkdir -p "$STUBDIR"
        printf '#!/bin/sh\ntrue\n' >"$STUBDIR/.probe"; chmod +x "$STUBDIR/.probe"
        "$STUBDIR/.probe" 2>/dev/null || {
            echo "FATAL: cannot create an executable stub — assertions would be vacuous" >&2
            return 1
        }
    fi
}

teardown() {
    [[ "$STUBDIR" == "$HOME/.cache/"* ]] && rm -rf "$STUBDIR"
    return 0
}

load_fn() {  # load_fn <file> <function>: define one top-level function only
    local body
    body=$(sed -n "/^$2() {/,/^}/p" "$1")
    [ -n "$body" ] || { echo "function $2 not found in $1" >&2; return 1; }
    eval "$body"
}

key48=013574062458099132038016086790025795074679720885

# ── deployer ────────────────────────────────────────────────────────────────

@test "deployer moves the key into the installed root, 0600, then shreds the NTFS copy" {
    log() { echo "LOG $*"; }; err() { echo "ERR $*"; }
    load_fn "$DEPLOY" persist_bitlocker_key
    mkdir -p "$T/ntfs/wootc/install" "$T/root"
    printf '%s\n' "$key48" > "$T/ntfs/wootc/install/bitlocker-key.txt"

    run persist_bitlocker_key "$T/ntfs/wootc/install/bitlocker-key.txt" "$T/root"
    [ "$status" -eq 0 ]
    [ "$(cat "$T/root/etc/wootc/bitlocker-key")" = "$key48" ]
    [ "$(stat -c %a "$T/root/etc/wootc/bitlocker-key")" = 600 ]
    [ ! -e "$T/ntfs/wootc/install/bitlocker-key.txt" ]
    [ ! -e "$T/root/etc/wootc/bitlocker-key.partial" ]
}

@test "deployer keeps the NTFS copy when the move cannot be completed" {
    log() { echo "LOG $*"; }; err() { echo "ERR $*"; }
    load_fn "$DEPLOY" persist_bitlocker_key
    mkdir -p "$T/ntfs" "$T/root/etc"
    printf '%s\n' "$key48" > "$T/ntfs/bitlocker-key.txt"
    : > "$T/root/etc/wootc"   # a file where the directory must go

    run persist_bitlocker_key "$T/ntfs/bitlocker-key.txt" "$T/root"
    [ "$status" -ne 0 ]
    [ "$(cat "$T/ntfs/bitlocker-key.txt")" = "$key48" ]
    [[ "$output" == *"keeping the NTFS copy"* ]]
}

@test "deployer does nothing on a machine with no BitLocker key" {
    log() { echo "LOG $*"; }; err() { echo "ERR $*"; }
    load_fn "$DEPLOY" persist_bitlocker_key
    mkdir -p "$T/root"
    run persist_bitlocker_key "$T/absent/bitlocker-key.txt" "$T/root"
    [ "$status" -eq 0 ]
    [ ! -e "$T/root/etc/wootc" ]
}

@test "deployer persists the key after DEPLOY_ROOT is resolved, inside the verified-root block" {
    local resolved call boot
    resolved=$(grep -n 'DEPLOY_ROOT="/mnt/verify"' "$DEPLOY" | head -1 | cut -d: -f1)
    call=$(grep -n '^    persist_bitlocker_key ' "$DEPLOY" | head -1 | cut -d: -f1)
    boot=$(grep -n 'VERIFY_BOOT="\${VERIFY_LOOP}p2"' "$DEPLOY" | head -1 | cut -d: -f1)
    [ -n "$resolved" ] && [ -n "$call" ] && [ -n "$boot" ]
    [ "$call" -gt "$resolved" ]
    [ "$call" -lt "$boot" ]
    # Best-effort: a key problem must never abort an otherwise good deploy.
    sed -n "${call}p" "$DEPLOY" | grep -q '"\$DEPLOY_ROOT" || true$'
}

@test "the key move uses only binaries the deployer initramfs ships" {
    # module-setup.sh's inst_multiple has no cmp, id or dirname; a missing
    # binary under set -e kills the deploy (run 20260723T1331 was dirname).
    local body
    body=$(sed -n '/^persist_bitlocker_key() {/,/^}/p' "$DEPLOY" | grep -v '^[[:space:]]*#')
    [ -n "$body" ]
    run grep -nwE 'cmp|id|dirname' <<< "$body"
    [ "$status" -ne 0 ]
    for tool in install chown mv shred sync sha256sum; do
        grep -qw "$tool" "$REPO_ROOT/payload/deployer/module-setup.sh"
    done
}

# ── bridge ──────────────────────────────────────────────────────────────────

@test "bridge prefers the installed root's key over an NTFS copy" {
    load_fn "$MOUNT" bitlocker_key_file
    WOOTC_ETC="$T/etc/wootc"; HOST="$T/host"
    mkdir -p "$WOOTC_ETC" "$HOST/wootc/install"
    echo etc > "$WOOTC_ETC/bitlocker-key"
    echo ntfs > "$HOST/wootc/install/bitlocker-key.txt"
    run bitlocker_key_file
    [ "$status" -eq 0 ]
    [ "$output" = "$WOOTC_ETC/bitlocker-key" ]
}

@test "bridge falls back to the NTFS copy for older deployments" {
    load_fn "$MOUNT" bitlocker_key_file
    WOOTC_ETC="$T/etc/wootc"; HOST="$T/host"
    mkdir -p "$HOST/wootc/install"
    echo ntfs > "$HOST/wootc/install/bitlocker-key.txt"
    run bitlocker_key_file
    [ "$status" -eq 0 ]
    [ "$output" = "$HOST/wootc/install/bitlocker-key.txt" ]
}

@test "bridge reports a missing key instead of guessing" {
    load_fn "$MOUNT" bitlocker_key_file
    WOOTC_ETC="$T/etc/wootc"; HOST="$T/host"
    mkdir -p "$HOST"
    run bitlocker_key_file
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "bridge reads the key through bitlocker_key_file and never deletes it" {
    sed -n '/^find_bitlocker_profiles() {/,/^}/p' "$MOUNT" > "$T/find.sh"
    grep -q 'key_file=$(bitlocker_key_file)' "$T/find.sh"
    run grep -nE 'shred|rm -f? *"?\$key_file' "$T/find.sh"
    [ "$status" -ne 0 ]
}

# ── shutdown ────────────────────────────────────────────────────────────────

@test "shutdown keeps the recovery key (the next boot needs it)" {
    # Every external command the script could reach is stubbed: nothing is
    # mounted, so nothing is unmounted or closed.
    printf '#!/bin/sh\nexit 1\n' > "$STUBDIR/mountpoint"
    printf '#!/bin/sh\necho "unexpected umount $*" >&2\nexit 1\n' > "$STUBDIR/umount"
    printf '#!/bin/sh\nexit 0\n' > "$STUBDIR/cryptsetup"
    chmod +x "$STUBDIR/mountpoint" "$STUBDIR/umount" "$STUBDIR/cryptsetup"
    mkdir -p "$T/host/wootc/install" "$T/etc/wootc"
    echo "$key48" > "$T/host/wootc/install/bitlocker-key.txt"
    echo "$key48" > "$T/etc/wootc/bitlocker-key"

    WOOTC_HOST="$T/host" WOOTC_ETC="$T/etc/wootc" PATH="$STUBDIR:$PATH" run bash "$UMOUNT"
    [ "$status" -eq 0 ]
    [ "$(cat "$T/host/wootc/install/bitlocker-key.txt")" = "$key48" ]
    [ "$(cat "$T/etc/wootc/bitlocker-key")" = "$key48" ]
    run grep -nE '^[^#]*\bshred\b' "$UMOUNT"
    [ "$status" -ne 0 ]
}

# ── conversion retires the key ──────────────────────────────────────────────

findmnt_stub() {  # findmnt_stub <SOURCE TARGET lines...>
    {
        echo '#!/bin/sh'
        echo "cat <<'EOF'"
        printf '%s\n' "$@"
        echo 'EOF'
    } > "$STUBDIR/findmnt"
    chmod +x "$STUBDIR/findmnt"
}

@test "converting the last bridged folder shreds the key" {
    log() { echo "LOG $*"; }
    load_fn "$CONVERT" retire_bitlocker_key_if_unused
    WOOTC_ETC="$T/etc/wootc"; export BITLK_MNT=/run/wootc/bitlk-tmp
    mkdir -p "$WOOTC_ETC"; echo "$key48" > "$WOOTC_ETC/bitlocker-key"
    findmnt_stub '/dev/vda3 /' '/dev/mapper/wootc-bitlk-812 /run/wootc/bitlk-tmp'
    PATH="$STUBDIR:$PATH" run retire_bitlocker_key_if_unused
    [ "$status" -eq 0 ]
    [ ! -e "$WOOTC_ETC/bitlocker-key" ]
    [[ "$output" == *"shredded"* ]]
}

@test "the key stays while any folder is still bridged from the Windows drive" {
    log() { echo "LOG $*"; }
    load_fn "$CONVERT" retire_bitlocker_key_if_unused
    WOOTC_ETC="$T/etc/wootc"; export BITLK_MNT=/run/wootc/bitlk-tmp
    mkdir -p "$WOOTC_ETC"; echo "$key48" > "$WOOTC_ETC/bitlocker-key"
    findmnt_stub '/dev/vda3 /' '/dev/mapper/wootc-bitlk-812 /run/wootc/bitlk-tmp' \
        '/dev/mapper/wootc-bitlk-812[/Users/alice/Pictures] /home/alice/Pictures'
    PATH="$STUBDIR:$PATH" run retire_bitlocker_key_if_unused
    [ "$status" -eq 0 ]
    [ "$(cat "$WOOTC_ETC/bitlocker-key")" = "$key48" ]
}

@test "the key stays when this boot never unlocked the Windows drive" {
    log() { echo "LOG $*"; }
    load_fn "$CONVERT" retire_bitlocker_key_if_unused
    WOOTC_ETC="$T/etc/wootc"; export BITLK_MNT=/run/wootc/bitlk-tmp
    mkdir -p "$WOOTC_ETC"; echo "$key48" > "$WOOTC_ETC/bitlocker-key"
    findmnt_stub '/dev/vda3 /'
    PATH="$STUBDIR:$PATH" run retire_bitlocker_key_if_unused
    [ "$status" -eq 0 ]
    [ "$(cat "$WOOTC_ETC/bitlocker-key")" = "$key48" ]
}

@test "convert-dir retires the key only after the conversion is recorded" {
    local recorded retire
    recorded=$(grep -n 'touch "$state_dir/converted-$folder"' "$CONVERT" | cut -d: -f1)
    retire=$(grep -n '^retire_bitlocker_key_if_unused$' "$CONVERT" | cut -d: -f1)
    [ -n "$recorded" ] && [ -n "$retire" ]
    [ "$retire" -gt "$recorded" ]
}

# ── recovery password format ────────────────────────────────────────────────
# cryptsetup's BITLK parser accepts a recovery password only as eight
# hyphen-separated groups of six digits; the 48 bare digits are a different
# passphrase and never unlock the protector. Phase 1 stores bare digits, the
# E2E fixture stores the hyphenated form; both must reach cryptsetup hyphenated.

canonical=013574-062458-099132-038016-086790-025795-074679-720885

@test "a hyphenated recovery password reaches cryptsetup unchanged" {
    load_fn "$MOUNT" bitlocker_recovery_password
    printf '%s\r\n' "$canonical" > "$T/key"
    run bitlocker_recovery_password "$T/key"
    [ "$status" -eq 0 ]
    [ "$output" = "$canonical" ]
}

@test "the 48 bare digits Phase 1 stores are given their hyphens back" {
    load_fn "$MOUNT" bitlocker_recovery_password
    printf '%s\n' "${canonical//-/}" > "$T/key"
    run bitlocker_recovery_password "$T/key"
    [ "$status" -eq 0 ]
    [ "$output" = "$canonical" ]
    [ "${#output}" -eq 55 ]
}

@test "a recovery password with a bad group checksum or length is refused" {
    load_fn "$MOUNT" bitlocker_recovery_password
    printf '%s\n' "013575-062458-099132-038016-086790-025795-074679-720885" > "$T/key"
    run bitlocker_recovery_password "$T/key"
    [ "$status" -ne 0 ]
    printf '%s\n' "720896-062458-099132-038016-086790-025795-074679-720885" > "$T/key"
    run bitlocker_recovery_password "$T/key"
    [ "$status" -ne 0 ]
    printf '%s\n' "013574-062458-099132" > "$T/key"
    run bitlocker_recovery_password "$T/key"
    [ "$status" -ne 0 ]
    : > "$T/key"
    run bitlocker_recovery_password "$T/key"
    [ "$status" -ne 0 ]
}

@test "the bridge never hands cryptsetup a password with its hyphens stripped" {
    sed -n '/^find_bitlocker_profiles() {/,/^}/p' "$MOUNT" > "$T/find.sh"
    grep -q 'recovery_key=$(bitlocker_recovery_password "$key_file")' "$T/find.sh"
    run grep -n "tr -d '\[:space:\]-'" "$T/find.sh"
    [ "$status" -ne 0 ]
}
