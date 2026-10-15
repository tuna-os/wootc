# shellcheck shell=bash
fixture_capture_windows_boot() {
    local target="$1" query
    query=$(cat "$SCRIPT_DIR/windows-boot-observation.ps1") || return 1
    [[ -n "$query" ]] || return 1
    WOOTC_QGA_CALL_TIMEOUT=15 qga_powershell "$query" \
        > "$target" 2> "$target.stderr"
}

# shellcheck disable=SC2086 # DOCKER may contain the established privileged runtime prefix.
fixture_qmp_optical_command() {
    timeout 20 $DOCKER cp "$SCRIPT_DIR/qmp-optical-media.py" "$CONTAINER_NAME:/tmp/wootc-optical-media.py" || return 1
    local expected
    expected=$(sha256sum "$SCRIPT_DIR/qmp-optical-media.py") || return 1
    expected=${expected%% *}
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    # shellcheck disable=SC2016 # Source hash comparison runs inside the selected container.
    timeout 20 $DOCKER exec "$CONTAINER_NAME" sh -c '
        observed=$(sha256sum /tmp/wootc-optical-media.py) || exit 1
        [ "${observed%% *}" = "$1" ] || exit 1
        exec python3 /tmp/wootc-optical-media.py --socket /run/shm/wootc-control/qmp.sock --timeout 15 --allow /storage/win11x64.iso
    ' sh "$expected"
}

# Called before setup/GUI can schedule the deployer. No eject/enrollment replay.
fixture_detach_optical_media() {
    local before="$ARTIFACT_DIR/optical-windows-before.json" after="$ARTIFACT_DIR/optical-windows-after.json"
    fixture_capture_windows_boot "$before" || return 1
    python3 "$SCRIPT_DIR/verify-fixture-boot-observation.py" --before "$before" --after "$before" \
        --mode same --run-id "$RUN_ID" > "$ARTIFACT_DIR/optical-before-windows-identity.json" || return 1
    fixture_qmp_optical_command > "$ARTIFACT_DIR/optical-removal.raw.json" \
        2> "$ARTIFACT_DIR/optical-removal.stderr" || return 1
    python3 "$SCRIPT_DIR/verify-optical-detach-receipt.py" "$ARTIFACT_DIR/optical-removal.raw.json" \
        --allow /storage/win11x64.iso --run-id "$RUN_ID" --source "$SCRIPT_DIR/qmp-optical-media.py" \
        --context "$ARTIFACT_DIR/optical-source-run-context.json" > "$ARTIFACT_DIR/optical-removal.json" || return 1
    fixture_capture_windows_boot "$after" || return 1
    python3 "$SCRIPT_DIR/verify-fixture-boot-observation.py" --before "$before" --after "$after" \
        --mode same --run-id "$RUN_ID" > "$ARTIFACT_DIR/optical-same-windows-boot.json"
}

# A reboot after ISO removal is a prerequisite for one later TPM enrollment.
fixture_verify_windows_boot_after_detach() {
    local current="$ARTIFACT_DIR/optical-windows-returned.json"
    fixture_capture_windows_boot "$current" || return 1
    python3 "$SCRIPT_DIR/verify-fixture-boot-observation.py" \
        --before "$ARTIFACT_DIR/optical-windows-after.json" --after "$current" \
        --mode changed --run-id "$RUN_ID" > "$ARTIFACT_DIR/optical-subsequent-windows-boot.json"
}
