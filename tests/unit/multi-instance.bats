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
