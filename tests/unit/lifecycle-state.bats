#!/usr/bin/env bats
# Lifecycle state contract pins: state.json, deployer-started.json, first-boot health.
# Contract: docs/borrowed-from-libertix.md §2, docs/gui-phase1-architecture.md §2.3

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export WOOTC_STEPS_FILE="$REPO_ROOT/payload/steps.sh"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    MODULE_SETUP="$REPO_ROOT/payload/deployer/module-setup.sh"
    FIRSTBOOT_SCRIPT="$REPO_ROOT/payload/migration/wootc-firstboot-evidence"
    FIRSTBOOT_SERVICE="$REPO_ROOT/payload/migration/wootc-firstboot-evidence.service"
    INSTALLER_WIN="$REPO_ROOT/app/installer_windows.go"
    STATE_GO="$REPO_ROOT/app/state.go"
}

make_firstboot_fakes() {
    local tmp="$1"
    mkdir -p "$tmp/bin" "$tmp/host/wootc/install"
    cat > "$tmp/bin/mountpoint" <<'SH'
#!/bin/sh
[ "${FIRSTBOOT_MOUNT_PRESENT:-0}" = 1 ]
SH
    cat > "$tmp/bin/wootc-ntfs-state-write" <<'SH'
#!/bin/bash
set -e
template="$1"
target="$2"
printf '%s\n' "$target" >> "$FIRSTBOOT_HELPER_CALLS"
if [ ! -f "$template" ]; then
    echo "missing descriptor template: $template" >&2
    exit 2
fi
if [[ ${FIRSTBOOT_FAIL_STATE_WRITE:-0} == 1 && "$target" == */wootc/state.json ]]; then
    echo "injected state write failure" >&2
    exit 72
fi
cat > "$target"
SH
    # Stand-in for the measured boot: the real collector has its own suite
    # (tests/unit/test_wootc_firstboot_evidence.py).
    cat > "$tmp/collector.py" <<'PY'
import json, os, sys
assert sys.argv[1:3] == ['--host', os.environ['WOOTC_FIRSTBOOT_HOST']], sys.argv
if os.environ.get('FIRSTBOOT_COLLECT_FAIL') == '1':
    print('first-boot evidence unavailable: injected', file=sys.stderr)
    sys.exit(1)
print(json.dumps({'schema': 1, 'state': 'healthy', 'bootId': '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0',
                  'updatedBy': 'wootc-firstboot'}, indent=2))
PY
    chmod +x "$tmp/bin/mountpoint" "$tmp/bin/wootc-ntfs-state-write"
    export WOOTC_FIRSTBOOT_COLLECTOR="$tmp/collector.py"
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

@test "deployer metadata uses the descriptor-preserving atomic writer" {
    for function in write_ntfs_state write_deployer_started; do
        run sed -n "/^${function}()/,/^}/p" "$DEPLOY"
        [ "$status" -eq 0 ]
        echo "$output" | grep -q 'wootc-ntfs-state-write /mnt/ntfs/wootc/state.json'
    done
}

@test "wootc-firstboot-evidence exists and writes state.json = healthy atomically" {
    [ -f "$FIRSTBOOT_SCRIPT" ]
    [ -x "$FIRSTBOOT_SCRIPT" ]
    grep -q 'installed-linux-boot.json' "$FIRSTBOOT_SCRIPT"
    grep -q '"state": "healthy"' "$FIRSTBOOT_SCRIPT"
    grep -q 'state.json' "$FIRSTBOOT_SCRIPT"
    [ "$(grep -c '^wootc-ntfs-state-write ' "$FIRSTBOOT_SCRIPT")" -eq 2 ]
}

@test "wootc-firstboot-evidence.service is ordered after host-bind" {
    [ -f "$FIRSTBOOT_SERVICE" ]
    grep -q 'After=.*wootc-host-bind.service' "$FIRSTBOOT_SERVICE"
    # The bridge summary is measured from the mount table, so the user
    # folders must already be bound when the evidence is collected.
    grep -q '^After=.*wootc-passthrough.service' "$FIRSTBOOT_SERVICE"
    grep -q '^Type=oneshot$' "$FIRSTBOOT_SERVICE"
    grep -q 'Requires=wootc-host-bind.service' "$FIRSTBOOT_SERVICE"
    grep -q 'ConditionPathExists=!/run/initramfs/wootc-host/wootc/install/installed-linux-boot.json' "$FIRSTBOOT_SERVICE"
}

@test "firstboot service PATH includes the staged NTFS state writer" {
    grep -q '^Environment=PATH=/var/usrlocal/bin:' "$FIRSTBOOT_SERVICE"
    grep -q '^ExecStart=/var/usrlocal/bin/wootc-firstboot-evidence$' "$FIRSTBOOT_SERVICE"
}

@test "firstboot health writer publishes readable state and evidence" {
    tmp=$(mktemp -d)
    make_firstboot_fakes "$tmp"
    printf '{"state":"deployed"}\n' > "$tmp/host/wootc/state.json"

    run env FIRSTBOOT_MOUNT_PRESENT=1 WOOTC_FIRSTBOOT_HOST="$tmp/host" \
        FIRSTBOOT_HELPER_CALLS="$tmp/helper-calls" \
        PATH="$tmp/bin:$PATH" bash "$FIRSTBOOT_SCRIPT"
    [ "$status" -eq 0 ]
    python3 -c 'import json,sys; state=json.load(open(sys.argv[1])); evidence=json.load(open(sys.argv[2])); assert state["state"] == "healthy" and state["updatedBy"] == "wootc-firstboot"; assert evidence["state"] == "healthy" and evidence["updatedBy"] == "wootc-firstboot"' \
        "$tmp/host/wootc/state.json" "$tmp/host/wootc/install/installed-linux-boot.json"
    [ "$(sed -n '1p' "$tmp/helper-calls")" = "$tmp/host/wootc/state.json" ]
    [ "$(sed -n '2p' "$tmp/helper-calls")" = "$tmp/host/wootc/install/installed-linux-boot.json" ]
    rm -rf "$tmp"
}

@test "firstboot evidence is the collector's measurement, written atomically after state" {
    tmp=$(mktemp -d)
    make_firstboot_fakes "$tmp"
    printf '{"state":"deployed"}\n' > "$tmp/host/wootc/state.json"

    run env FIRSTBOOT_MOUNT_PRESENT=1 WOOTC_FIRSTBOOT_HOST="$tmp/host" \
        FIRSTBOOT_HELPER_CALLS="$tmp/helper-calls" \
        PATH="$tmp/bin:$PATH" bash "$FIRSTBOOT_SCRIPT"
    [ "$status" -eq 0 ]
    WOOTC_FIRSTBOOT_HOST="$tmp/host" python3 "$tmp/collector.py" --host "$tmp/host" > "$tmp/expected"
    cmp "$tmp/expected" "$tmp/host/wootc/install/installed-linux-boot.json"
    # Both records go through the descriptor-preserving temp-and-rename writer.
    [ "$(wc -l < "$tmp/helper-calls")" -eq 2 ]
    rm -rf "$tmp"
}

@test "firstboot writes nothing when the boot cannot be measured" {
    tmp=$(mktemp -d)
    make_firstboot_fakes "$tmp"
    printf '{"state":"deployed"}\n' > "$tmp/host/wootc/state.json"

    run env FIRSTBOOT_MOUNT_PRESENT=1 FIRSTBOOT_COLLECT_FAIL=1 WOOTC_FIRSTBOOT_HOST="$tmp/host" \
        FIRSTBOOT_HELPER_CALLS="$tmp/helper-calls" \
        PATH="$tmp/bin:$PATH" bash "$FIRSTBOOT_SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not measure this boot"* ]]
    [ "$(cat "$tmp/host/wootc/state.json")" = '{"state":"deployed"}' ]
    [ ! -e "$tmp/host/wootc/install/installed-linux-boot.json" ]
    [ ! -e "$tmp/helper-calls" ]
    rm -rf "$tmp"
}

@test "firstboot never overwrites evidence a previous boot recorded" {
    tmp=$(mktemp -d)
    make_firstboot_fakes "$tmp"
    printf '{"state":"deployed"}\n' > "$tmp/host/wootc/state.json"
    printf 'first boot\n' > "$tmp/host/wootc/install/installed-linux-boot.json"

    run env FIRSTBOOT_MOUNT_PRESENT=1 WOOTC_FIRSTBOOT_HOST="$tmp/host" \
        FIRSTBOOT_HELPER_CALLS="$tmp/helper-calls" \
        PATH="$tmp/bin:$PATH" bash "$FIRSTBOOT_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already recorded"* ]]
    [ "$(cat "$tmp/host/wootc/install/installed-linux-boot.json")" = 'first boot' ]
    [ "$(cat "$tmp/host/wootc/state.json")" = '{"state":"deployed"}' ]
    [ ! -e "$tmp/helper-calls" ]
    rm -rf "$tmp"
}

@test "firstboot refuses to create the Windows install directory itself" {
    tmp=$(mktemp -d)
    make_firstboot_fakes "$tmp"
    rmdir "$tmp/host/wootc/install"
    printf '{"state":"deployed"}\n' > "$tmp/host/wootc/state.json"

    run env FIRSTBOOT_MOUNT_PRESENT=1 WOOTC_FIRSTBOOT_HOST="$tmp/host" \
        FIRSTBOOT_HELPER_CALLS="$tmp/helper-calls" \
        PATH="$tmp/bin:$PATH" bash "$FIRSTBOOT_SCRIPT"
    [ "$status" -ne 0 ]
    [ ! -e "$tmp/host/wootc/install" ]
    [ ! -e "$tmp/helper-calls" ]
    rm -rf "$tmp"
}

@test "firstboot health writer fails when the private Windows mount is absent" {
    tmp=$(mktemp -d)
    make_firstboot_fakes "$tmp"

    run env FIRSTBOOT_MOUNT_PRESENT=0 WOOTC_FIRSTBOOT_HOST="$tmp/host" \
        FIRSTBOOT_HELPER_CALLS="$tmp/helper-calls" \
        PATH="$tmp/bin:$PATH" bash "$FIRSTBOOT_SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not mounted"* ]]
    [ ! -f "$tmp/host/wootc/state.json" ]
    [ ! -f "$tmp/host/wootc/install/installed-linux-boot.json" ]
    [ ! -e "$tmp/helper-calls" ]
    rm -rf "$tmp"
}

@test "firstboot does not publish its retry marker when the state write fails" {
    tmp=$(mktemp -d)
    make_firstboot_fakes "$tmp"
    printf '{"state":"deployed"}\n' > "$tmp/host/wootc/state.json"

    run env WOOTC_FIRSTBOOT_HOST="$tmp/host" \
        FIRSTBOOT_MOUNT_PRESENT=1 FIRSTBOOT_FAIL_STATE_WRITE=1 \
        FIRSTBOOT_HELPER_CALLS="$tmp/helper-calls" \
        PATH="$tmp/bin:$PATH" bash "$FIRSTBOOT_SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"first-boot state write failed"* ]]
    [ "$(cat "$tmp/host/wootc/state.json")" = '{"state":"deployed"}' ]
    [ ! -e "$tmp/host/wootc/install/installed-linux-boot.json" ]
    [ "$(wc -l < "$tmp/helper-calls")" -eq 1 ]
    [ "$(cat "$tmp/helper-calls")" = "$tmp/host/wootc/state.json" ]
    rm -rf "$tmp"
}

@test "first-boot evidence payload is staged by deploy.sh and shipped in module-setup.sh" {
    grep -q 'inst /usr/lib/wootc/migration/wootc-firstboot-evidence' "$MODULE_SETUP"
    grep -q 'inst /usr/lib/wootc/migration/wootc-firstboot-evidence.service' "$MODULE_SETUP"
    grep -q 'wootc-firstboot-evidence.service' "$DEPLOY"
    grep -q 'etc/systemd/system/multi-user.target.wants/wootc-firstboot-evidence.service' "$DEPLOY"
    # The collector and the EFI decoder it imports reach the installed image
    # even when the signed-chain helpers were not staged.
    grep -q 'migration/lib/wootc_firstboot_evidence.py' "$DEPLOY"
    grep -q 'migration/lib/wootc_boot_identity.py' "$DEPLOY"
    grep -q 'COLLECTOR="${WOOTC_FIRSTBOOT_COLLECTOR:-/var/usrlocal/lib/wootc/wootc_firstboot_evidence.py}"' "$FIRSTBOOT_SCRIPT"
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
