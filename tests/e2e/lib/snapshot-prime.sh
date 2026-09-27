# shellcheck shell=bash
# Actual snapshot-prime branch; QGA/container primitives are injected by caller.
prime_snapshot() {
    command -v qemu-img >/dev/null 2>&1 || { infra_fail "WOOTC_E2E_SNAPSHOT_OUT requires qemu-img (install qemu-utils)"; return 1; }
    step "Priming Windows base image → $SNAPSHOT_OUT (clean shutdown, then compress)"
    mkdir -p "$SNAPSHOT_OUT" || { infra_fail "prime: cannot create snapshot output directory"; return 1; }

    qga_windows_probe || { infra_fail "prime: positive Windows identity required before fixture mutation"; return 1; }
    infra_pass snapshot-windows-identity "Prime: positive Windows_NT identity confirmed"

    # Future snapshots must remain usable after the local password ages.
    gui_prepare_account || { capture_vm_diagnostics; return 1; }

    # Clean guest shutdown so C:/NTFS is left with its dirty bit CLEAR.
    qga_powershell 'Stop-Computer -Force' >/dev/null 2>&1 \
        || qga_call exec /bin/sh -c 'shutdown /s /t 0' >/dev/null 2>&1 || true
    info "Waiting for the guest to power off cleanly (QGA to go away)..."
    prime_deadline=$(deadline_in 300)
    while ! past_deadline "$prime_deadline"; do
        qga_windows_probe || break   # QGA unreachable == guest powered off
        sleep 5
    done

    # Drop the container so nothing holds data.qcow2 open, THEN convert.
    $COMPOSE -f compose.yml down 2>/dev/null || $DOCKER stop "$CONTAINER_NAME" 2>/dev/null || true
    [ -s "$STORAGE_DIR/data.qcow2" ] || { infra_fail "prime: data.qcow2 missing/empty after install"; return 1; }

    step "Compressing base image (qemu-img convert -c → standalone qcow2)..."
    qemu-img convert -c -O qcow2 "$STORAGE_DIR/data.qcow2" "$SNAPSHOT_OUT/data.qcow2" \
        || { infra_fail "prime: qemu-img convert failed"; return 1; }
    [ -s "$SNAPSHOT_OUT/data.qcow2" ] || { infra_fail "prime: compressed snapshot missing/empty"; return 1; }
    infra_pass snapshot-compressed "Prime: compressed qcow2 bytes exist after successful conversion"
    # dockur's installed-markers so a restore does not trigger a reinstall.
    for f in "$STORAGE_DIR"/windows.*; do
        [ -e "$f" ] || continue
        cp "$f" "$SNAPSHOT_OUT/" || { infra_fail "prime: cannot copy Windows install marker"; return 1; }
    done
    # The correctness key the restore side validates against (same formula as
    # ANSWER_SHA), doubling as the answer-file stamp the reuse guard checks.
    { sha256sum < "$RENDERED_ANSWER"; echo "$WIN_VERSION"; } | sha256sum | awk '{print $1}' \
        > "$SNAPSHOT_OUT/snapshot.key" || { infra_fail "prime: cannot write snapshot correctness key"; return 1; }
    cp "$SNAPSHOT_OUT/snapshot.key" "$SNAPSHOT_OUT/.wootc-autounattend.sha256" || { infra_fail "prime: cannot copy snapshot correctness stamp"; return 1; }
    local expected_key actual_key
    expected_key=$({ sha256sum < "$RENDERED_ANSWER"; echo "$WIN_VERSION"; } | sha256sum | awk '{print $1}')
    actual_key=$(cat "$SNAPSHOT_OUT/snapshot.key")
    [[ "$actual_key" =~ ^[0-9a-f]{64}$ ]] && [ "$actual_key" = "$expected_key" ] && cmp -s "$SNAPSHOT_OUT/snapshot.key" "$SNAPSHOT_OUT/.wootc-autounattend.sha256" || {
        infra_fail "prime: snapshot correctness key or copied stamp differs"; return 1;
    }
    infra_pass snapshot-key "Prime: snapshot key matches the current answer and Windows version"
    wootc_result_finish "$WOOTC_RESULT_LEDGER" "$RUN_ID" "$WOOTC_FAILURE_LEDGER" "" "$IMAGE_REF" || return 1
    ls -lh "$SNAPSHOT_OUT" >&2 || true
    pass "Pristine Windows base image ready at $SNAPSHOT_OUT (key $(cat "$SNAPSHOT_OUT/snapshot.key"))"
}
