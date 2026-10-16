#!/usr/bin/env bats
#
# The composefs MOK cert harvest asks the container image for the certs the
# deployment tree cannot show. It used to run `podman run --rm "$IMAGE"`
# without --network=host and with stderr discarded: the probe shape #633
# showed failing spuriously in the initramfs, and a probe that could not run
# then looked exactly like an image that ships no certs.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    WORK="$(mktemp -d)"
    mkdir -p "$WORK/bin" "$WORK/stash"
    export CALLS="$WORK/calls"
    : > "$CALLS"
    export TMPDIR="$WORK"
    export PATH="$WORK/bin:$PATH"
    export IMAGE="ghcr.io/example/image:stable"
}

teardown() {
    rm -rf "$WORK"
}

load_helpers() {
    {
        echo 'log() { echo "LOG $*"; }'
        echo 'err() { echo "ERR $*"; }'
        sed -n '/^MOK_CERT_PROBE=/p' "$DEPLOY"
        sed -n '/^PROBE_ERR=/p' "$DEPLOY"
        for fn in probe_image harvest_mok_certs_from_image; do
            sed -n "/^${fn}() {/,/^}/p" "$DEPLOY"
        done
    } > "$WORK/helpers.sh"
    # shellcheck disable=SC1091
    source "$WORK/helpers.sh"
}

stub_podman() {  # <body run after recording argv>
    printf '#!/usr/bin/env bash\necho "podman $*" >> "$CALLS"\n%s\n' "$1" > "$WORK/bin/podman"
    chmod +x "$WORK/bin/podman"
}

@test "the cert harvest runs through probe_image, with --network=host" {
    load_helpers
    mkdir -p "$WORK/src/etc/pki/akmods/certs"
    printf 'cert' > "$WORK/src/etc/pki/akmods/certs/akmods-ublue.der"
    stub_podman "tar -C '$WORK/src' -cf - etc/pki/akmods/certs/akmods-ublue.der"
    harvest_mok_certs_from_image "$WORK/stash"
    grep -q -- "podman run --rm --network=host $IMAGE sh -c" "$CALLS"
    [ -f "$WORK/stash/etc/pki/akmods/certs/akmods-ublue.der" ]
}

@test "a cert probe that cannot run says so, with podman's stderr" {
    load_helpers
    stub_podman 'echo "Error: netavark: nftables error: nft did not return successfully" >&2; exit 125'
    run harvest_mok_certs_from_image "$WORK/stash"
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not inspect $IMAGE for certs"* ]]
    [[ "$output" == *"probe exit 125"* ]]
    [[ "$output" == *"netavark: nftables error"* ]]
}

@test "an image with no certs is not reported as a probe failure" {
    load_helpers
    stub_podman 'tar -cf - -T /dev/null'
    run harvest_mok_certs_from_image "$WORK/stash"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WARN"* ]]
    [ -z "$(ls -A "$WORK/stash")" ]
}

@test "the cert harvest keeps its own 180s bound" {
    load_helpers
    stub_podman 'exit 0'
    timeout() { echo "timeout $1" >> "$CALLS"; shift; "$@"; }
    harvest_mok_certs_from_image "$WORK/stash"
    grep -qx 'timeout 180' "$CALLS"
}

@test "no podman run on \$IMAGE in the deployer lacks --network=host" {
    runs=$(grep -nE '^[^#]*podman run[^#]*"\$IMAGE"' "$DEPLOY")
    [ -n "$runs" ]
    offenders=$(printf '%s\n' "$runs" | grep -v -- '--network=host' || true)
    [ -z "$offenders" ]
}
