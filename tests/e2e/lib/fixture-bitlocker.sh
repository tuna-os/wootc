# shellcheck shell=bash
# A recovery password can exist while C: is still converting. Do not boot the
# Linux BitLocker consumer until Windows reports the supported fixture state.
bitlocker_wait_fixture_ready() {
    local timeout_s="${1:-1800}" deadline remaining call_timeout result pause
    deadline="${2:-$(deadline_in "$timeout_s")}"
    while ! past_deadline "$deadline"; do
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -gt 0 ] || break
        call_timeout=$remaining
        [ "$call_timeout" -le 10 ] || call_timeout=10
        # shellcheck disable=SC2016 # Literal PowerShell variables.
        if result=$(WOOTC_QGA_CALL_TIMEOUT="$call_timeout" qga_powershell '$ErrorActionPreference="Stop"; . "C:\OEM\fixture-bitlocker-readiness.ps1"; Get-WootcFixtureBitLockerReadiness' 2>/dev/null); then
            result=$(printf '%s' "$result" | tr -d '\r')
            if [[ "$result" =~ ^bitlocker-fixture\ status=(FullyDecrypted|FullyEncrypted|EncryptionInProgress|DecryptionInProgress|EncryptionPaused|DecryptionPaused)\ percentage=(100|[0-9]{1,2})\ protection=(On|Off|Unknown)\ ready=(True|False)$ ]]; then
                info "$result"
                if [[ "$result" == 'bitlocker-fixture status=FullyEncrypted percentage=100 protection=On ready=True' ]] && ! past_deadline "$deadline"; then
                    pass "BitLocker fixture C: fully encrypted, 100%, protection on"
                    return 0
                fi
            else
                info "BitLocker fixture observation malformed; readiness not established"
            fi
        else
            info "BitLocker fixture observation unavailable; readiness not established"
        fi
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -gt 0 ] || break
        pause=$remaining
        [ "$pause" -le 5 ] || pause=5
        sleep "$pause"
    done
    fail "BitLocker fixture C: not positively ready within $timeout_s s; installed Linux boot was not scheduled"
    return 1
}

# Dedicated fixture activation and final read-only readiness share one deadline.
bitlocker_prepare_fixture() {
    local timeout_s="${1:-1800}" deadline remaining limit result root activation
    deadline=$(deadline_in "$timeout_s")
    while ! past_deadline "$deadline"; do
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -gt 0 ] || break
        limit=$remaining; [ "$limit" -le 10 ] || limit=10
        if result=$(WOOTC_QGA_CALL_TIMEOUT="$limit" qga_powershell '$ErrorActionPreference="Stop"; . "C:\OEM\fixture-bitlocker-readiness.ps1"; Get-WootcFixtureBitLockerReadiness' 2>/dev/null); then
            result=$(printf '%s' "$result" | tr -d '\r')
            if [[ "$result" =~ ^bitlocker-fixture\ status=(FullyDecrypted|FullyEncrypted|EncryptionInProgress|DecryptionInProgress|EncryptionPaused|DecryptionPaused)\ percentage=(100|[0-9]{1,2})\ protection=(On|Off|Unknown)\ ready=(True|False)$ ]]; then
                info "$result"
            fi
            if [[ "$result" =~ ^bitlocker-fixture\ status=FullyEncrypted\ percentage=100\ protection=(On|Off)\ ready=(True|False)$ ]] && ! past_deadline "$deadline"; then
                break
            fi
        fi
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -gt 0 ] || break
        limit=$remaining; [ "$limit" -le 5 ] || limit=5
        sleep "$limit"
    done
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || { infra_fail "BitLocker fixture conversion did not complete within $timeout_s s; Linux was not scheduled"; return 1; }
    # Identity is independent from QGA liveness and precedes any fixture write.
    WOOTC_QGA_CALL_TIMEOUT="$remaining" qga_windows_probe || { infra_fail "BitLocker fixture activation requires positive Windows identity"; return 1; }
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || return 1
    # One actual tree, never the guest_wootc_root fallback to C:.
    root=$(WOOTC_QGA_CALL_TIMEOUT="$remaining" qga_powershell 'Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { Test-Path ($_.Name + ":\wootc\install") } | Select-Object -ExpandProperty Name' 2>/dev/null | tr -d '[:space:]') || return 1
    case "$root" in [A-Za-z]) root="${root}:" ;; *) infra_fail "BitLocker fixture storage root unavailable or ambiguous"; return 1 ;; esac
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || return 1
    activation="$ARTIFACT_DIR/bitlocker-activation.txt"
    printf '%s\n' "$RUN_ID" > "$ARTIFACT_DIR/bitlocker-activation-run-id.txt" || return 1
    # A timeout/failure does not replay enrollment. This command is called once.
    # Its only output is whitelisted before metadata and the final observation.
    if ! WOOTC_QGA_CALL_TIMEOUT="$remaining" qga_powershell '$ErrorActionPreference="Stop"; . "C:\OEM\fixture-bitlocker-key.ps1"; . "C:\OEM\fixture-bitlocker-protection.ps1"; Initialize-WootcFixtureBitLockerProtection -RecoveryKeyPath '"'$root\wootc\install\bitlocker-key.txt'" \
        2>&1 | python3 "$SCRIPT_DIR/safe-log.py" > "$activation"; then
        infra_fail "BitLocker fixture activation failed or timed out; enrollment will not be replayed"; return 1
    fi
    python3 "$SCRIPT_DIR/fixture-bitlocker-receipt.py" "$activation" || { infra_fail "BitLocker fixture activation has no valid current receipt"; return 1; }
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || { infra_fail "BitLocker fixture activation exceeded its deadline"; return 1; }
    # No activation receipt substitutes for an independent ProtectionOn readback.
    bitlocker_wait_fixture_ready "$remaining" "$deadline"
}
