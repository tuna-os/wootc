#!/usr/bin/env bats

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WORK="$BATS_TEST_TMPDIR/probe"
    mkdir -p "$WORK/host/wootc/install"
    # Public synthetic format fixture; never capture a real machine key.
    PASSWORD=$(printf '%s-' 000011 000022 000033 000044 000055 000066 000077 000088)
    PASSWORD=${PASSWORD%-}
    printf '%s\r\n' "$PASSWORD" > "$WORK/host/wootc/install/bitlocker-key.txt"
    export ROOT WORK
}

run_password_stanza() {
    run bash -c '
set -euo pipefail
HOST="$WORK/host"
key_file="$HOST/wootc/install/bitlocker-key.txt"
bl_vol=/dev/sda3
log() { printf "%s\n" "$*"; }
warn() { printf "%s\n" "$*" >&2; }
mkdir() { command mkdir -p "$WORK/mnt"; }
rmdir() { command rmdir "$WORK/mnt"; }
cryptsetup() {
    python3 -c "import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(sys.stdin.buffer.read())" "$WORK/submitted-key"
    return "${UNLOCK_RC:-2}"
}
probe() {
    eval "$(sed -n "/^    # cryptsetup recognizes recovery/,/^    log \"BitLocker volume/p" "$ROOT/payload/migration/wootc-mount-user-dirs")"
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

@test "BitLocker consumer rejects stripped digits, BOM, extra lines and invalid groups before unlock" {
    for kind in stripped bom extra_line bad_checksum excessive_group; do
        case "$kind" in
            stripped) printf '%s\n' "${PASSWORD//-/}" > "$WORK/host/wootc/install/bitlocker-key.txt" ;;
            bom) printf '\357\273\277%s\n' "$PASSWORD" > "$WORK/host/wootc/install/bitlocker-key.txt" ;;
            extra_line) printf '%s\nextra\n' "$PASSWORD" > "$WORK/host/wootc/install/bitlocker-key.txt" ;;
            bad_checksum) printf '%s\n' "000012-${PASSWORD#*-}" > "$WORK/host/wootc/install/bitlocker-key.txt" ;;
            excessive_group) printf '%s\n' "720896-${PASSWORD#*-}" > "$WORK/host/wootc/install/bitlocker-key.txt" ;;
        esac
        rm -f "$WORK/submitted-key"
        run_password_stanza
        [ "$status" -eq 0 ]
        [[ "$output" == *"format invalid"* ]]
        [ ! -e "$WORK/submitted-key" ]
        [[ "$output" != *"$PASSWORD"* ]]
    done
}

@test "BitLocker consumer accepts valid maximum groups and a line without an ending newline" {
    printf '%s' "720885-${PASSWORD#*-}" > "$WORK/host/wootc/install/bitlocker-key.txt"
    run_password_stanza
    [ "$status" -eq 0 ]
    [ "$(wc -c < "$WORK/submitted-key")" -eq 55 ]
    [[ "$output" == *"password format validated"* ]]
}
