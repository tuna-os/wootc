#!/usr/bin/env bats
# Multi-instance harness contract: N concurrent VMs per host (run-matrix
# --jobs). Every mutable path must be instance-scoped; shared paths must be
# read-only or atomically written.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
    MATRIX="$REPO_ROOT/tests/e2e/run-matrix.sh"
    COMPOSE="$REPO_ROOT/tests/e2e/compose.yml"
}

@test "run-e2e accepts --instance= and derives disjoint state from it" {
    grep -q -- '--instance=\*)' "$E2E"
    grep -q 'CONTAINER_NAME="wootc-e2e-windows-\$WOOTC_E2E_INSTANCE"' "$E2E"
    grep -q 'STORAGE_DIR="\$SCRIPT_DIR/storage-\$WOOTC_E2E_INSTANCE"' "$E2E"
    # The rendered OEM payload (per-case wootc-config.txt) must be private
    # too — a shared ./oem hands one case's config to the other guest.
    grep -q 'OEM_DIR="\$STORAGE_DIR/oem"' "$E2E"
}

@test "compose volumes and container name are instance-parameterized" {
    grep -q 'container_name: ${WOOTC_E2E_CONTAINER:-wootc-e2e-windows}' "$COMPOSE"
    grep -q '\${WOOTC_E2E_STORAGE_VOL:-./storage}:/storage' "$COMPOSE"
    grep -q '\${WOOTC_E2E_OEM_VOL:-./oem}:/oem:ro' "$COMPOSE"
    run grep -nE '^\s+- \./storage:/storage' "$COMPOSE"
    [ "$status" -ne 0 ]
}

@test "matrix per-slot cleanup is scoped to its own instance" {
    # A bare `pkill -f run-e2e.sh` from slot a murders slot b mid-case.
    grep -q 'pkill -9 -f "run-e2e.sh.\*--instance=\$inst"' "$MATRIX"
    run grep -nE '^[^#]*pkill -9 -f run-e2e\.sh 2' "$MATRIX"
    [ "$status" -ne 0 ]
    grep -q 'podman rm -f "\$ctr"' "$MATRIX"
}

@test "matrix sizes runners instead of assuming capacity" {
    grep -q 'size_host()' "$MATRIX"
    grep -q 'WOOTC_E2E_RAM_SIZE="\${vm_ram}G"' "$MATRIX"
    # RAM never sized below Windows 11's viable floor.
    grep -q '"\$vm_ram" -lt 5' "$MATRIX"
}

@test "concurrent deployer builds are serialized, artifacts written atomically" {
    grep -q '.build.lock' "$E2E"
    grep -qE 'flock 8' "$E2E"
    grep -q 'mv -f "\$tmp_output" "\$output"' "$E2E"
}

@test "GUI-driven install path: seeds, drives the live form, rejoins normal flow" {
    grep -q -- '--gui-install)  GUI_INSTALL=true' "$E2E"
    # Seeding must happen in the GUI path too — the OEM path seeds inside
    # snapshot_before_deployer, which the GUI path never reaches.
    grep -A6 'gui_install_arm() {' "$E2E" | grep -q 'seed_user_data'
    # Drive mode over the app's own bridge — CDP is impossible in stock
    # wails (both loaders drop the env var once the framework passes its own
    # browser args; proven live 20260723T1044/1115).
    grep -q 'WOOTC_E2E_DRIVE=1' "$E2E"
    grep -q 'e2e-drive.json' "$E2E"
    grep -q 'installDriven' "$E2E"
    # The driver runs the REAL pipeline: preview mode must not be set here.
    run bash -c "grep -A40 'gui_install_arm() {' '$E2E' | grep 'WOOTC_UI_PREVIEW'"
    [ "$status" -ne 0 ]
    # Go persists the BCD GUID for the harness's Phase-2 scheduling; the
    # app's drive bindings stay inert without the env gate.
    grep -q 'bcd-guid.txt' "$REPO_ROOT/app/installer_windows.go"
    grep -q 'WOOTC_E2E_DRIVE' "$REPO_ROOT/app/app.go"
    grep -q 'E2EDriveDirective' "$REPO_ROOT/app/frontend/src/main.js"
}

@test "matrix poll ssh cannot eat the case queue" {
    # ssh without -n inherits slot_worker's while-read stdin — the queue —
    # and the worker silently stops after one case (run 20260723T0953).
    grep -q 'ssh -n -o ConnectTimeout=8 -o BatchMode=yes' "$MATRIX"
    run bash -c "grep -nE 's=\\\$\\(ssh -o' '$MATRIX'"
    [ "$status" -ne 0 ]
}

@test "fresh runs reclaim their own disposable disk before preflight" {
    # Preflight used to count the run's own stale data.qcow2 against the
    # budget — one failed case then poisoned every later case on that slot
    # (run 20260723T1054: the whole queue burned in 2s intervals).
    grep -B4 'host_preflight || exit 1' "$E2E" | grep -q 'rm -f "\$STORAGE_DIR/data.qcow2" "\$STORAGE_DIR/custom.iso"'
    # And the fresh-path clean uses the instance dir, not a literal storage/.
    run grep -nE '^[^#]*rm -rf storage/data.qcow2' "$E2E"
    [ "$status" -ne 0 ]
}

@test "registry mirror is an opt-in, probed hint at every layer" {
    # Concurrent deployers starved each other's multi-GB pulls (podman
    # exit-125, runs 20260723T1130/1201). The mirror must degrade to direct
    # pulls when absent or dead — probe before trust, at both ends.
    grep -q 'mirror.txt' "$E2E"
    grep -q 'setup-registry-cache.sh' "$E2E"
    local dep="$REPO_ROOT/payload/deployer/deploy.sh"
    grep -q 'MIRROR_FILE=' "$dep"
    grep -A3 'WOOTC_MIRROR=$(tr' "$dep" | grep -q 'curl -fsS -m 3'
    grep -q 'registries.conf.d/wootc-mirror.conf' "$dep"
    grep -q 'mirror.txt' "$REPO_ROOT/tests/e2e/setup-wootc.ps1"
}

@test "post-deploy parsing survives no-match greps (pipefail)" {
    # `set -euo pipefail` + a grep that matches nothing = silent death with
    # no fail line. The GUI path has no OEM log, so the BitLocker-axis
    # parse killed takes 7b and 8 right after a fully verified deploy.
    grep -q "{ grep -aoE 'C: BitLocker state: \[a-z\]+' || true; }" "$E2E"
    grep -q "{ grep -aoE 'WOOTC_STORAGE_ROOT=\[A-Za-z\]:' || true; }" "$E2E"
}

@test "a failed run tears the VM down even under --keep" {
    # A VM left in a Phase-2 emergency shell churns qemu+kcryptd on
    # encrypted btrfs and froze the host into a power-cycle (2026-07-24).
    # Diagnostics are already captured and evidence is in data.qcow2, so a
    # failed guest is force-downed unless WOOTC_E2E_KEEP_ALIVE=1.
    grep -q 'WOOTC_E2E_KEEP_ALIVE' "$E2E"
    grep -q 'result" -ne 0 \] && \[ "${WOOTC_E2E_KEEP_ALIVE:-0}" != "1" \]' "$E2E"
    grep -q "pkill -9 -f 'process=windows'" "$E2E"
}
