#!/usr/bin/env bats
# compose-startup.bats — container startup must fail fast and attributably.
#
# compose.yml references localhost/wootc-e2e-windows-ssh:latest, an image that
# only exists because build-ssh-image.sh made it LOCALLY. On a host that never
# built it — a fresh GitHub hosted runner, or a laptop after
# `podman system prune -af` — compose reads "localhost/..." as a REGISTRY and
# tries to pull over HTTPS from localhost:443:
#
#   initializing source docker://localhost/wootc-e2e-windows-ssh:latest:
#   pinging container registry localhost: dial tcp [::1]:443: connection refused
#   Error: no container with name or ID "wootc-e2e-windows" found
#
# That is how the first hosted-runner E2E failed, and a kanpur run after I
# pruned its images. In BOTH cases the real error was buried: compose_up_windows
# was called with its return value ignored, so the script printed "Container
# started" and then polled 15 minutes for a QEMU that could never appear,
# finally reporting "QEMU did not start" — which points at entirely the wrong
# thing.
#
# Two fixes, both pinned here: build the image before compose needs it, and
# never claim the container started without checking that it exists.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
}

@test "run-e2e.sh is syntactically valid" {
    run bash -n "$E2E"
    [ "$status" -eq 0 ]
}

@test "the ssh image is built BEFORE compose needs it" {
    grep -q '^ensure_ssh_image()' "$E2E"
    # called at the top of compose_up_windows, before pick_free_ports
    local body
    body=$(sed -n '/^compose_up_windows()/,/^}/p' "$E2E")
    echo "$body" | grep -q 'ensure_ssh_image || return 1'
}

@test "a failed image build aborts instead of proceeding" {
    local body
    body=$(sed -n '/^ensure_ssh_image()/,/^}/p' "$E2E")
    echo "$body" | grep -q 'build-ssh-image.sh failed'
    echo "$body" | grep -q 'return 1'
}

@test "the build is verified to have actually produced the image" {
    # A build script exiting 0 without producing the image is the same class of
    # lie as compose exiting 0 without creating the container.
    sed -n '/^ensure_ssh_image()/,/^}/p' "$E2E" | grep -q 'build completed but .* still absent'
}

@test "compose_up_windows's return value is NOT ignored" {
    # `compose_up_windows` bare on its own line was the original bug.
    run grep -nE '^compose_up_windows$' "$E2E"
    [ "$status" -ne 0 ]
    grep -q 'if ! compose_up_windows; then' "$E2E"
}

@test "container existence is verified even when compose reports success" {
    # podman-compose can exit 0 without creating the container, so the exit
    # status alone is not evidence.
    grep -q 'container exists "\$CONTAINER_NAME"' "$E2E"
    grep -q 'compose reported success but' "$E2E"
}

@test "the failure message names the actual cause and the fix" {
    # "QEMU did not start within 15 minutes" sent debugging to the wrong place
    # twice. The message must name the missing image and the rebuild command.
    grep -q 'build-ssh-image.sh' "$E2E"
    grep -q "compose tried to pull 'localhost" "$E2E"
}

@test "startup failure exits rather than falling through to the QEMU wait" {
    local block
    block=$(sed -n '/if ! compose_up_windows; then/,/^fi$/p' "$E2E")
    echo "$block" | grep -q 'exit 1'
}
