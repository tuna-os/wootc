# shellcheck shell=bash
# Source-only: the BitLocker cell's second Phase-2 boot (#279).
# The bridge unlocks encrypted C: read-only on every Phase-2 boot and imports
# Documents into the persistent Linux workspace. A single boot cannot prove
# that the recovery key survives shutdown or that the editable copy survives
# restart, so this helper checks both before returning to Windows.
#
# Callers provide the run's QGA helpers (qga-transport.sh), the result API
# (result-runner.sh) and RUN_ID, with Windows booted and identified. Sourcing
# this file performs no guest or host action.

# phase2_second_boot_check <bcd-guid> <storage-root> <reset-command> [<userdata-path>] [<while-up>]
#   <bcd-guid>       the wootc Phase-2 firmware entry, e.g. {xxxxxxxx-...}
#   <storage-root>   the volume holding \wootc, e.g. E:
#   <reset-command>  how to power-cycle a Linux guest that ignores a reboot
#   <userdata-path>  where the seeded Documents file is in the Linux home;
#                    the BitLocker bridge copies Documents to "From Windows"
#   <while-up>       a command run while this second boot is still up, after
#                    the user-data and key checks (e.g. the Documents edit
#                    persistence checks)
# Records user-data-second-boot on success. Returns non-zero when the second
# boot could not be completed and Windows could not be brought back.
#
# The recovery key is kept for every boot and sealed to the machine (#279):
# this second boot must unlock C: with the sealed copy, and no plaintext copy
# may remain on the installed system or on the Windows volume.
phase2_second_boot_check() {
    local guid="$1" root="$2" reset="$3" path="${4:-/home/wootc/Documents/wootc-e2e-userdata.txt}" while_up="${5:-}"
    local disk size deadline seen userdata diag original served_from_bitlocker=false
    step "BitLocker: booting Phase 2 a second time — the bridge must still unlock C: (#279)"

    # Same preparation as the first boot. Phase 2 may have written root.disk
    # through ntfs-3g, which can leave its ValidDataLength short again.
    disk="${root}\\wootc\\disks\\root.disk"
    # shellcheck disable=SC2016
    size=$(qga_powershell "(Get-Item '$disk').Length" 2>/dev/null | tr -d '\r\n' || true)
    if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ]; then
        qga_powershell "fsutil file setvaliddata '$disk' $size" >/dev/null 2>&1 || true
    fi
    qga_powershell "bcdedit --% /set {fwbootmgr} bootsequence $guid /addfirst" >/dev/null 2>&1 || true
    if ! qga_powershell "bcdedit --% /enum {fwbootmgr}" 2>/dev/null | tr -d '\r' | grep -qiF "$guid"; then
        infra_fail "Second Phase 2 boot: BCD bootsequence was not set to $guid"
        return 1
    fi
    qga_powershell 'cmd.exe /c "shutdown.exe /a >NUL 2>&1 & shutdown.exe /r /t 1 /f >NUL 2>&1"' >/dev/null 2>&1 || true
    qga_wait_down "second Phase 2 boot" 300 || return 1

    # Require a positively identified Linux agent. Windows answering again
    # means the one-shot was not taken or Phase 2 failed and fell back.
    seen=""
    deadline=$(deadline_in 600)
    while ! past_deadline "$deadline"; do
        if qga_linux_probe; then seen=linux; break; fi
        if qga_windows_probe; then seen=windows; break; fi
        sleep 10
    done
    case "$seen" in
        linux) pass "Second Phase 2 boot: Linux agent identified" ;;
        windows)
            product_fail "Second Phase 2 boot did not happen: Windows answered after the one-shot reboot"
            return 0 ;;
        *)
            infra_fail "Second Phase 2 boot: no agent identified itself within 10 minutes"
            return 1 ;;
    esac

    # The bridge is a boot-time service; poll for it as the first boot does.
    userdata=""
    deadline=$(deadline_in 180)
    while ! past_deadline "$deadline"; do
        userdata=$(qga_call exec /bin/sh -c \
            "cat '$path' 2>/dev/null" 2>/dev/null || true)
        printf '%s' "$userdata" | grep -q "$RUN_ID" && break
        sleep 5
    done
    diag=$(qga_call exec /bin/sh -c \
        'echo "boot-id: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"; \
         echo "etc-key: $(stat -c "%a %U:%G" /etc/wootc/bitlocker-key 2>&1)"; \
         echo "sealed-key: $(stat -c "%a %U:%G %s bytes" /etc/wootc/bitlocker-key.cred 2>&1)"; \
         echo "ntfs-key: $(ls /run/initramfs/wootc-host/wootc/install/bitlocker-key.txt 2>/dev/null || echo absent)"; \
         echo "home-bind: $(findmnt -n -o SOURCE /home/wootc/Documents 2>/dev/null || echo ABSENT)"; \
         echo "bitlk-mount: $(findmnt -n -o SOURCE /run/wootc/bitlk-tmp 2>/dev/null || echo ABSENT)"; \
         journalctl -b -u wootc-passthrough --no-pager 2>/dev/null | grep -aiE "bitlocker|recovery key" | tail -12' \
        2>/dev/null || true)
    source_doc=$(qga_call exec /bin/sh -c \
        'f=$(find /run/wootc/bitlk-tmp/Users -type f -name wootc-e2e-userdata.txt -print -quit); [ -n "$f" ] && tr -d "\r" < "$f"' \
        2>/dev/null || true)
    printf '%s\n' "$diag" | sed 's/^/  /'
    # The seeded original, read on the encrypted C: as this boot unlocked it.
    original=$(qga_call exec /bin/sh -c \
        'f=$(find /run/wootc/bitlk-tmp/Users -type f -name wootc-e2e-userdata.txt -print -quit 2>/dev/null); [ -n "$f" ] && tr -d "\r" < "$f"' \
        2>/dev/null || true)
    # Say which path served the file. Only C: unlocked through the BitLocker
    # mapper exercises the recovery key: either Documents is bound from it,
    # or (the editable copy) this boot read the seeded original on it. A
    # fixture that seeds the profile on the unencrypted volume proves the
    # second boot, not the key, and must not be reported as if it did.
    if printf '%s' "$diag" | grep -q '^home-bind: /dev/mapper/wootc-bitlk-' ||
        { printf '%s' "$diag" | grep -q '^bitlk-mount: /dev/mapper/wootc-bitlk-' &&
          printf '%s' "$original" | grep -q "$RUN_ID"; }; then
        served_from_bitlocker=true
    fi
    if printf '%s' "$userdata" | grep -q "$RUN_ID"; then
        if [ "$served_from_bitlocker" = true ]; then
            product_pass user-data-second-boot "Second Phase 2 boot: Windows Documents file still readable in /home/wootc, served from the unlocked BitLocker C:"
        else
            product_pass user-data-second-boot "Second Phase 2 boot: imported Documents copy survived"
            warn "Second Phase 2 boot: BitLocker unlock was not observed ($(printf '%s' "$diag" | grep -iE 'home-bind:|bitlocker|recovery key' | tail -1))"
            if [ "${WOOTC_E2E_GUI_DOCUMENTS:-0}" = 1 ]; then
                product_fail "GUI Documents: second boot did not prove that the recovery key unlocked the Windows source"
            fi
        fi
        if ! printf '%s' "$source_doc" | grep -Fxq "wootc-e2e-userdata $RUN_ID" \
            || { [ -n "${EDIT_MARKER:-}" ] && printf '%s' "$source_doc" | grep -Fq "$EDIT_MARKER"; }; then
            product_fail "BitLocker Documents: Windows source changed or could not be verified after restart"
        else
            pass "BitLocker Documents: Windows source stayed unchanged after restart"
        fi
        if [ "${WOOTC_E2E_GUI_DOCUMENTS:-0}" = 1 ]; then
            if ! python3 "$SCRIPT_DIR/gui-document-proof.py" reopen --runtime "$DOCKER" \
                --container "$CONTAINER_NAME" --path "$userdata_path" --run-id "$RUN_ID" \
                --output "$ARTIFACT_DIR/gui-documents/second-boot" \
                > "$ARTIFACT_DIR/gui-documents-second.json"; then
                product_fail "GUI Documents: editor could not reopen saved bytes after the environment restart"
            elif [ "$(jq -r '.sha256' "$ARTIFACT_DIR/gui-documents-second.json")" != "${GUI_EDIT_SHA:-}" ]; then
                product_fail "GUI Documents: saved bytes changed across the environment restart"
            else
                pass "GUI Documents: real editor reopened the same saved bytes after restart"
            fi
        fi
    else
        product_fail "Second Phase 2 boot: Windows Documents file NOT readable at $userdata_path (expected RUN_ID $RUN_ID) — the recovery key did not survive the first shutdown"
    fi

    # The key that unlocked C: on this boot is the copy sealed to this
    # machine: the bridge says which file it used, and neither plaintext copy
    # (/etc/wootc/bitlocker-key, \wootc\install\bitlocker-key.txt) remains.
    if [ "$served_from_bitlocker" = true ]; then
        if printf '%s' "$diag" | grep -q 'recovery key found sealed at /etc/wootc/bitlocker-key.cred' &&
            printf '%s' "$diag" | grep -q '^sealed-key: 600 root:root ' &&
            printf '%s' "$diag" | grep -q '^etc-key: .*No such file' &&
            printf '%s' "$diag" | grep -qx 'ntfs-key: absent'; then
            pass "Second Phase 2 boot: C: unlocked with the recovery key sealed to this machine; no plaintext copy remains"
        else
            product_fail "Second Phase 2 boot: C: was not unlocked with a sealed recovery key, or a plaintext copy remains (see the key lines above)"
        fi
    fi

    if [ -n "$while_up" ]; then
        "$while_up"
    fi

    # Back to Windows, with the first return's rules: a bounded request, and a
    # reset only on a positively identified Linux agent.
    WOOTC_QGA_CALL_TIMEOUT=5 qga_call exec /bin/sh -c 'systemctl reboot || systemctl reboot -ff' 2>/dev/null || true
    case "$(p2_reboot_observe)" in
        linux)
            info "Second Phase 2 boot: Linux still answering after the reboot request — resetting"
            "$reset" || true ;;
        *) ;;
    esac
    qga_wait_windows 600 || return 1
    pass "Second Phase 2 boot: Windows returned"
}

# The same QEMU-monitor reset the first Phase-2 return uses. Callers reach it
# only from a positively identified Linux agent (see above).
phase2_monitor_reset() {
    "${DOCKER:?}" exec "${CONTAINER_NAME:?}" python3 -c 'import socket,time; s=socket.socket(socket.AF_UNIX); s.connect("/run/shm/monitor.sock"); time.sleep(.2); s.recv(4096); s.sendall(b"system_reset\n"); time.sleep(.4); s.recv(4096); s.close()'
}
