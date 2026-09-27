# shellcheck shell=bash
fixture_optical_remaining() {
    local deadline="$1" cap="$2" remaining
    remaining=$((deadline - $(date +%s)))
    [[ "$remaining" -gt 0 ]] || return 1
    [[ "$remaining" -le "$cap" ]] || remaining=$cap
    printf '%s\n' "$remaining"
}
fixture_capture_windows_boot() {
    local target="$1" deadline="${2:-$(( $(date +%s) + 15 ))}" query limit
    query=$(cat "$SCRIPT_DIR/windows-boot-observation.ps1") || return 1
    [[ -n "$query" ]] || return 1
    limit=$(fixture_optical_remaining "$deadline" 15) || return 1
    WOOTC_QGA_CALL_TIMEOUT="$limit" qga_powershell "$query" \
        > "$target" 2> "$target.stderr"
}

# shellcheck disable=SC2086 # DOCKER may contain the established privileged runtime prefix.
fixture_qmp_optical_command() {
    local mode="${1:-detach}" deadline="${2:-$(( $(date +%s) + 40 ))}" limit helper_limit
    case "$mode" in detach|check-empty) ;; *) return 1 ;; esac
    limit=$(fixture_optical_remaining "$deadline" 20) || return 1
    timeout "$limit" $DOCKER cp "$SCRIPT_DIR/qmp-optical-media.py" "$CONTAINER_NAME:/tmp/wootc-optical-media.py" || return 1
    local expected
    expected=$(sha256sum "$SCRIPT_DIR/qmp-optical-media.py") || return 1
    expected=${expected%% *}
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    limit=$(fixture_optical_remaining "$deadline" 20) || return 1
    helper_limit=$(fixture_optical_remaining "$deadline" 15) || return 1
    # shellcheck disable=SC2016 # Expressions run inside the selected container.
    timeout "$limit" $DOCKER exec "$CONTAINER_NAME" sh -c '
        observed=$(sha256sum /tmp/wootc-optical-media.py) || exit 1
        [ "${observed%% *}" = "$1" ] || exit 1
        mode="$2"; bound="$3"
        case "$mode" in check-empty) set -- --check-empty ;; detach) set -- ;; *) exit 1 ;; esac
        exec python3 /tmp/wootc-optical-media.py --socket /run/shm/wootc-control/qmp.sock --timeout "$bound" --allow /storage/win11x64.iso "$@"
    ' sh "$expected" "$mode" "$helper_limit"
}

# Called before setup/GUI can schedule the deployer. No eject/enrollment replay.
fixture_detach_optical_media() {
    local before="$ARTIFACT_DIR/optical-windows-before.json" after="$ARTIFACT_DIR/optical-windows-after.json" deadline
    deadline=$(( $(date +%s) + 75 ))
    fixture_capture_windows_boot "$before" "$deadline" || return 1
    python3 "$SCRIPT_DIR/verify-fixture-boot-observation.py" --before "$before" --after "$before" \
        --mode same --run-id "$RUN_ID" > "$ARTIFACT_DIR/optical-before-windows-identity.json" || return 1
    fixture_qmp_optical_command detach "$deadline" > "$ARTIFACT_DIR/optical-removal.raw.json" \
        2> "$ARTIFACT_DIR/optical-removal.stderr" || return 1
    python3 "$SCRIPT_DIR/verify-optical-detach-receipt.py" "$ARTIFACT_DIR/optical-removal.raw.json" \
        --allow /storage/win11x64.iso --run-id "$RUN_ID" --source "$SCRIPT_DIR/qmp-optical-media.py" \
        --context "$ARTIFACT_DIR/optical-source-run-context.json" > "$ARTIFACT_DIR/optical-removal.json" || return 1
    fixture_capture_windows_boot "$after" "$deadline" || return 1
    python3 "$SCRIPT_DIR/verify-fixture-boot-observation.py" --before "$before" --after "$after" \
        --mode same --run-id "$RUN_ID" > "$ARTIFACT_DIR/optical-same-windows-boot.json" || return 1
    fixture_optical_remaining "$deadline" 1 >/dev/null
}

# A reboot after ISO removal is a prerequisite for one later TPM enrollment.
fixture_verify_windows_boot_after_detach() {
    local deadline="$1" current="$ARTIFACT_DIR/optical-windows-returned.json" after="$ARTIFACT_DIR/optical-windows-preactivation-after.json"
    fixture_optical_remaining "$deadline" 1 >/dev/null || return 1
    fixture_capture_windows_boot "$current" "$deadline" || return 1
    python3 "$SCRIPT_DIR/verify-fixture-boot-observation.py" \
        --before "$ARTIFACT_DIR/optical-windows-after.json" --after "$current" \
        --mode changed --run-id "$RUN_ID" > "$ARTIFACT_DIR/optical-subsequent-windows-boot.json" || return 1
    fixture_qmp_optical_command check-empty "$deadline" > "$ARTIFACT_DIR/optical-preactivation.raw.json" \
        2> "$ARTIFACT_DIR/optical-preactivation.stderr" || return 1
    python3 "$SCRIPT_DIR/verify-optical-detach-receipt.py" "$ARTIFACT_DIR/optical-preactivation.raw.json" \
        --mode check-empty --prior "$ARTIFACT_DIR/optical-removal.json" --allow /storage/win11x64.iso \
        --run-id "$RUN_ID" --source "$SCRIPT_DIR/qmp-optical-media.py" \
        --context "$ARTIFACT_DIR/optical-preactivation-source-run-context.json" > "$ARTIFACT_DIR/optical-preactivation.json" || return 1
    fixture_capture_windows_boot "$after" "$deadline" || return 1
    python3 "$SCRIPT_DIR/verify-fixture-boot-observation.py" --before "$current" --after "$after" \
        --mode same --run-id "$RUN_ID" > "$ARTIFACT_DIR/optical-preactivation-same-windows-boot.json" || return 1
    fixture_optical_remaining "$deadline" 1 >/dev/null
}
