# shellcheck shell=bash
# Only safe text leaves this boundary. Private scratch is never an artifact.
qga_safe_log() {
    local output errors result=0
    output=$(mktemp "${TMPDIR:-/tmp}/wootc-safe-stdout.XXXXXX") || return 1
    errors=$(mktemp "${TMPDIR:-/tmp}/wootc-safe-stderr.XXXXXX") || { rm -f "$output"; return 1; }
    qga_read "$1" > "$output" 2> "$errors" || result=$?
    python3 "$SCRIPT_DIR/safe-log.py" < "$output" || result=1
    python3 "$SCRIPT_DIR/safe-log.py" < "$errors" >&2 || result=1
    rm -f "$output" "$errors"
    return "$result"
}

collect_windows_diagnostic_metadata() {
    qga_windows_probe || return 1
    local found
    # All matching drives are returned. Ambiguity must not select an old tree.
    found=$(qga_powershell 'Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { Test-Path ($_.Name + ":\wootc\install") } | Select-Object -ExpandProperty Name' 2>/dev/null | tr -d '[:space:]') || return 1
    case "$found" in
        [A-Za-z]) WOOTC_GUEST_ROOT="${found}:" ;;
        *) printf '%s\n' 'Actual wootc storage root unavailable or ambiguous' > "$ARTIFACT_DIR/storage-root.txt"; return 1 ;;
    esac
    printf '%s\n' "$WOOTC_GUEST_ROOT" > "$ARTIFACT_DIR/storage-root.txt"
    # Select individual nonsecret properties, never format a KeyProtector object.
    qga_powershell '$ErrorActionPreference="Stop"; $v=Get-BitLockerVolume -MountPoint "C:"; $t=Get-Tpm; [ordered]@{mountPoint="C:";volumeStatus=[string]$v.VolumeStatus;encryptionPercentage=$v.EncryptionPercentage;protectionStatus=[string]$v.ProtectionStatus;tpmPresent=$t.TpmPresent;tpmReady=$t.TpmReady;protectors=@($v.KeyProtector | ForEach-Object { [ordered]@{type=[string]$_.KeyProtectorType;id=[string]$_.KeyProtectorId} })} | ConvertTo-Json -Depth 4 -Compress' 2>&1 | python3 "$SCRIPT_DIR/safe-log.py" > "$ARTIFACT_DIR/bitlocker-metadata.json" || return 1
}
