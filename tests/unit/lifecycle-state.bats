#!/usr/bin/env bats
# Lifecycle state contract pins: state.json, deployer-started.json, first-boot health.
# Contract: docs/borrowed-from-libertix.md §2, docs/gui-phase1-architecture.md §2.3

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    MODULE_SETUP="$REPO_ROOT/payload/deployer/module-setup.sh"
    FIRSTBOOT_SCRIPT="$REPO_ROOT/payload/migration/wootc-firstboot-evidence"
    FIRSTBOOT_SERVICE="$REPO_ROOT/payload/migration/wootc-firstboot-evidence.service"
    INSTALLER_WIN="$REPO_ROOT/app/installer_windows.go"
    STATE_GO="$REPO_ROOT/app/state.go"
}

@test "deploy.sh is syntactically valid" {
    run bash -n "$DEPLOY"
    [ "$status" -eq 0 ]
}

@test "wootc-firstboot-evidence is syntactically valid" {
    run bash -n "$FIRSTBOOT_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "deploy.sh writes deployer-started.json and state.json = deploying right after ntfs-mounted" {
    # Pin that write_deployer_started and write_ntfs_state "deploying" follow phase "ntfs-mounted"
    run grep -A5 'phase "ntfs-mounted"' "$DEPLOY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'write_deployer_started'
    echo "$output" | grep -q 'write_ntfs_state "deploying"'
}

@test "deploy.sh writes state.json = deployed after vstage verify-complete" {
    # Pin that write_ntfs_state "deployed" follows verify-complete
    run grep -A3 'vstage "verify-complete' "$DEPLOY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'write_ntfs_state "deployed"'
}

@test "deploy.sh cleanup writes state.json = failed with phase on non-zero exit" {
    # Pin cleanup() writes failed state while NTFS is mounted
    run grep -A40 'cleanup()' "$DEPLOY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'mountpoint -q /mnt/ntfs'
    echo "$output" | grep -q 'write_ntfs_state "failed"'
}

@test "deploy.sh writes state files atomically (temp file, sync, rename, sync)" {
    # write_ntfs_state must use temp file, rename, and sync
    run grep -A35 'write_ntfs_state()' "$DEPLOY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '\.tmp'
    echo "$output" | grep -q 'mv -f'
    echo "$output" | grep -q 'sync'

    # write_deployer_started must use temp file, rename, and sync
    run grep -A35 'write_deployer_started()' "$DEPLOY"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '\.tmp'
    echo "$output" | grep -q 'mv -f'
    echo "$output" | grep -q 'sync'
}

@test "wootc-firstboot-evidence exists and writes state.json = healthy atomically" {
    [ -f "$FIRSTBOOT_SCRIPT" ]
    [ -x "$FIRSTBOOT_SCRIPT" ]
    grep -q 'installed-linux-boot.json' "$FIRSTBOOT_SCRIPT"
    grep -q '"state": "healthy"' "$FIRSTBOOT_SCRIPT"
    grep -q 'state.json' "$FIRSTBOOT_SCRIPT"
    grep -q 'mv -f' "$FIRSTBOOT_SCRIPT"
    grep -q 'sync' "$FIRSTBOOT_SCRIPT"
}

@test "wootc-firstboot-evidence.service is ordered after host-bind" {
    [ -f "$FIRSTBOOT_SERVICE" ]
    grep -q 'After=.*wootc-host-bind.service' "$FIRSTBOOT_SERVICE"
    grep -q 'Requires=wootc-host-bind.service' "$FIRSTBOOT_SERVICE"
    grep -q 'ConditionPathExists=!/run/initramfs/wootc-host/wootc/install/installed-linux-boot.json' "$FIRSTBOOT_SERVICE"
}

@test "firstboot health writer publishes readable state and evidence" {
    tmp=$(mktemp -d)
    mkdir -p "$tmp/bin" "$tmp/host/wootc/install"
    cat > "$tmp/bin/mountpoint" <<'SH'
#!/bin/sh
[ "${FIRSTBOOT_MOUNT_PRESENT:-0}" = 1 ]
SH
    chmod +x "$tmp/bin/mountpoint"

    run env FIRSTBOOT_MOUNT_PRESENT=1 WOOTC_FIRSTBOOT_HOST="$tmp/host" \
        PATH="$tmp/bin:$PATH" bash "$FIRSTBOOT_SCRIPT"
    [ "$status" -eq 0 ]
    python3 -c 'import json,sys; state=json.load(open(sys.argv[1])); evidence=json.load(open(sys.argv[2])); assert state["state"] == "healthy" and state["updatedBy"] == "wootc-firstboot"; assert evidence["state"] == "healthy" and evidence["updatedBy"] == "wootc-firstboot"' \
        "$tmp/host/wootc/state.json" "$tmp/host/wootc/install/installed-linux-boot.json"
    rm -rf "$tmp"
}

@test "firstboot health writer fails when the private Windows mount is absent" {
    tmp=$(mktemp -d)
    mkdir -p "$tmp/bin" "$tmp/host/wootc/install"
    cat > "$tmp/bin/mountpoint" <<'SH'
#!/bin/sh
exit 1
SH
    chmod +x "$tmp/bin/mountpoint"

    run env FIRSTBOOT_MOUNT_PRESENT=0 WOOTC_FIRSTBOOT_HOST="$tmp/host" \
        PATH="$tmp/bin:$PATH" bash "$FIRSTBOOT_SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not mounted"* ]]
    [ ! -f "$tmp/host/wootc/state.json" ]
    [ ! -f "$tmp/host/wootc/install/installed-linux-boot.json" ]
    rm -rf "$tmp"
}

@test "firstboot does not publish its retry marker when the state rename fails" {
    tmp=$(mktemp -d)
    mkdir -p "$tmp/bin" "$tmp/host/wootc/install"
    cat > "$tmp/bin/mountpoint" <<'SH'
#!/bin/sh
exit 0
SH
    cat > "$tmp/bin/mv" <<'SH'
#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = "$FIRSTBOOT_FAIL_MV_DEST" ]; then
        exit 72
    fi
done
exec /usr/bin/mv "$@"
SH
    chmod +x "$tmp/bin/mountpoint" "$tmp/bin/mv"

    run env WOOTC_FIRSTBOOT_HOST="$tmp/host" \
        FIRSTBOOT_FAIL_MV_DEST="$tmp/host/wootc/state.json" \
        PATH="$tmp/bin:$PATH" bash "$FIRSTBOOT_SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"first-boot state write failed"* ]]
    [ ! -e "$tmp/host/wootc/state.json" ]
    [ ! -e "$tmp/host/wootc/install/installed-linux-boot.json" ]
    [ ! -e "$tmp/host/wootc/state.json.tmp" ]
    [ ! -e "$tmp/host/wootc/install/installed-linux-boot.json.tmp" ]
    rm -rf "$tmp"
}

@test "firstboot state is published before its retry-suppressing evidence marker" {
    state_line=$(grep -n 'mv -f "$STATE_TMP" "$STATE_FINAL"' "$FIRSTBOOT_SCRIPT" | cut -d: -f1)
    evidence_line=$(grep -n 'mv -f "$EVIDENCE_TMP" "$EVIDENCE_FINAL"' "$FIRSTBOOT_SCRIPT" | cut -d: -f1)
    [ -n "$state_line" ]
    [ -n "$evidence_line" ]
    [ "$state_line" -lt "$evidence_line" ]
    grep -q 'on_error' "$FIRSTBOOT_SCRIPT"
}

@test "first-boot evidence payload is staged by deploy.sh and shipped in module-setup.sh" {
    grep -q 'inst /usr/lib/wootc/migration/wootc-firstboot-evidence' "$MODULE_SETUP"
    grep -q 'inst /usr/lib/wootc/migration/wootc-firstboot-evidence.service' "$MODULE_SETUP"
    grep -q 'wootc-firstboot-evidence.service' "$DEPLOY"
    grep -q 'etc/systemd/system/multi-user.target.wants/wootc-firstboot-evidence.service' "$DEPLOY"
}

@test "deployHasCompleted stops trusting journal file alone" {
    # deployHasCompleted must not return true merely for deployer-last-journal.log
    run grep -A10 'func deployHasCompleted' "$INSTALLER_WIN"
    [ "$status" -eq 0 ]
    # Must NOT have os.Stat on deployer-last-journal.log returning true
    run bash -c "grep -A5 'func deployHasCompleted' '$INSTALLER_WIN' | grep 'deployer-last-journal.log'"
    [ "$status" -ne 0 ]
    # Must check StateDeployed or StateHealthy
    echo "$output" | grep -q 'StateDeployed' || grep -A10 'func deployHasCompleted' "$INSTALLER_WIN" | grep -q 'StateDeployed'
}

@test "state.go defines all six lifecycle states" {
    grep -q 'StateStaged.*= "staged"' "$STATE_GO"
    grep -q 'StateArmed.*= "armed"' "$STATE_GO"
    grep -q 'StateDeploying.*= "deploying"' "$STATE_GO"
    grep -q 'StateDeployed.*= "deployed"' "$STATE_GO"
    grep -q 'StateHealthy.*= "healthy"' "$STATE_GO"
    grep -q 'StateFailed.*= "failed"' "$STATE_GO"
}
