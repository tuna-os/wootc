#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    ARTIFACT_DIR="$BATS_TEST_TMPDIR/artifacts"
    mkdir -p "$ARTIFACT_DIR"
    # Load only the read-only capture helper, never the VM runner itself.
    eval "$(sed -n '/^capture_lifecycle_status() {/,/^}/p' "$REPO_ROOT/tests/e2e/run-e2e.sh")"
}

@test "lifecycle capture retains failing exit even when stdout claims healthy" {
    qga_powershell() {
        printf '{"state":"healthy"}\r\n'
        printf 'native guard error\n' >&2
        return 7
    }
    capture_lifecycle_status healthy
    [ "$_state_exit" -eq 7 ]
    [ "$_state_raw" = '{"state":"healthy"}' ]
    [ "$(cat "$ARTIFACT_DIR/status-healthy.stderr")" = 'native guard error' ]
    [ "$(cat "$ARTIFACT_DIR/status-healthy.exit")" = 7 ]
}

@test "lifecycle capture preserves successful output and separate empty stderr" {
    qga_powershell() { printf '{"state":"deployed"}\n'; }
    capture_lifecycle_status deployed
    [ "$_state_exit" -eq 0 ]
    [ "$_state_raw" = '{"state":"deployed"}' ]
    [ ! -s "$ARTIFACT_DIR/status-deployed.stderr" ]
}
