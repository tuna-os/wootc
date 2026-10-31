#!/usr/bin/env bats
# The bridge's BitLocker unlock stanza (payload/migration/wootc-mount-user-dirs),
# run as written with cryptsetup replaced by a recorder. The recovery password
# reaches cryptsetup only in canonical form, and never reaches the log.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WORK="$BATS_TEST_TMPDIR/probe"
    mkdir -p "$WORK/host/wootc/install"
    # Public synthetic format fixture; never capture a real machine key.
    PASSWORD=$(printf '%s-' 000011 000022 000033 000044 000055 000066 000077 000088)
    PASSWORD=${PASSWORD%-}
    KEY="$WORK/host/wootc/install/bitlocker-key.txt"
    printf '%s\r\n' "$PASSWORD" > "$KEY"
    export ROOT WORK KEY
}

run_password_stanza() {
    run bash -c '
set -euo pipefail
key_file="$KEY"
bl_vol=/dev/sda3
log() { printf "%s\n" "$*"; }
warn() { printf "%s\n" "$*" >&2; }
mkdir() { command mkdir -p "$WORK/mnt"; }
rmdir() { command rmdir "$WORK/mnt"; }
cryptsetup() {
    python3 -c "import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(sys.stdin.buffer.read())" "$WORK/submitted-key"
    return "${UNLOCK_RC:-2}"
}
eval "$(sed -n "/^bitlocker_recovery_password() {/,/^}/p" "$ROOT/payload/migration/wootc-mount-user-dirs")"
probe() {
    local key_material
    key_material=$(cat "$key_file")
    eval "$(sed -n "/^    # cryptsetup accepts a recovery password only/,/^    log \"BitLocker volume/p" "$ROOT/payload/migration/wootc-mount-user-dirs")"
}
probe
'
}

@test "BitLocker consumer preserves canonical separators and removes the CRLF terminator" {
    run_password_stanza
    [ "$status" -eq 0 ]
    [ "$(cat "$WORK/submitted-key")" = "$PASSWORD" ]
    [ "$(wc -c < "$WORK/submitted-key")" -eq 55 ]
    [[ "$output" == *"exit 2; password format validated"* ]]
    [[ "$output" != *"$PASSWORD"* ]]
}

@test "BitLocker consumer canonicalises the stored forms it accepts" {
    # Phase 1 stores the 48 digits without hyphens; a BOM or a trailing
    # non-digit line is not part of the password. Each reaches cryptsetup as
    # the same canonical 55-character password.
    for kind in stripped bom non_digit_line; do
        case "$kind" in
            stripped) printf '%s\n' "${PASSWORD//-/}" > "$KEY" ;;
            bom) printf '\357\273\277%s\n' "$PASSWORD" > "$KEY" ;;
            non_digit_line) printf '%s\nextra\n' "$PASSWORD" > "$KEY" ;;
        esac
        rm -f "$WORK/submitted-key"
        run_password_stanza
        [ "$status" -eq 0 ]
        [ "$(cat "$WORK/submitted-key")" = "$PASSWORD" ]
        [[ "$output" == *"password format validated"* ]]
        [[ "$output" != *"$PASSWORD"* ]]
    done
}

@test "BitLocker consumer rejects extra digits and invalid groups before unlock" {
    for kind in extra_digits short bad_checksum excessive_group; do
        case "$kind" in
            extra_digits) printf '%s\n000099\n' "$PASSWORD" > "$KEY" ;;
            short) printf '%s\n' "${PASSWORD%-*}" > "$KEY" ;;
            bad_checksum) printf '%s\n' "000012-${PASSWORD#*-}" > "$KEY" ;;
            excessive_group) printf '%s\n' "720896-${PASSWORD#*-}" > "$KEY" ;;
        esac
        rm -f "$WORK/submitted-key"
        run_password_stanza
        [ "$status" -eq 0 ]
        [[ "$output" == *"not a valid 48-digit recovery password"* ]]
        [ ! -e "$WORK/submitted-key" ]
        [[ "$output" != *"$PASSWORD"* ]]
    done
}

@test "BitLocker consumer accepts valid maximum groups and a line without an ending newline" {
    printf '%s' "720885-${PASSWORD#*-}" > "$KEY"
    run_password_stanza
    [ "$status" -eq 0 ]
    [ "$(wc -c < "$WORK/submitted-key")" -eq 55 ]
    [[ "$output" == *"password format validated"* ]]
}
