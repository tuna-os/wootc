#!/usr/bin/env bats
#
# The deployer's container scratch must fit the image it is about to pull.
#
# E2E run 38804321935 (bazzite-deck:stable, GUI install): every pull of the
# image into the fixed 20G scratch died with
#     writing blob: adding layer with blob …: … no space left on device
# — the ntfs-3g injection pull, its three `podman run` retries, the backend
# probe pull and finally fisherman's own pull — and the deployer reported the
# full disk as "(network/registry?)" because every pull ran `>/dev/null 2>&1`.
# containers/image keeps every compressed blob staged under /var/tmp (bind-
# mounted onto the scratch) until the whole pull ends, so a pull's peak is the
# compressed size PLUS the unpacked layers:
#     bazzite:stable       4.71 GiB + 12.67 GiB (4K blocks) = 17.4 GiB  (fits 20G)
#     bazzite-deck:stable  6.29 GiB + 14.49 GiB (4K blocks) = 20.8 GiB  (does not)

DECK_BYTES=6757057180     # sum of ghcr.io/ublue-os/bazzite-deck:stable layer sizes
BAZZITE_BYTES=5058316148  # sum of ghcr.io/ublue-os/bazzite:stable layer sizes

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    WORK="$(mktemp -d)"
    mkdir -p "$WORK/bin"
    export CALLS="$WORK/calls"
    : > "$CALLS"
}

teardown() {
    rm -rf "$WORK"
}

# Source only the helpers under test, with the deployer's logging stubbed.
load_helpers() {
    {
        echo 'set -Eeuo pipefail'
        echo 'log() { echo "LOG $*"; }'
        echo 'err() { echo "ERR $*"; }'
        echo 'splash_set() { echo "SPLASH $*" >> "$CALLS"; }'
        sed -n '/^SCRATCH_MIN_GIB=/p' "$DEPLOY"
        for fn in scratch_need_gib image_compressed_bytes scratch_too_small ensure_scratch_capacity acquire_image; do
            sed -n "/^${fn}() {/,/^}/p" "$DEPLOY"
        done
    } > "$WORK/helpers.sh"
    # shellcheck disable=SC1091
    source "$WORK/helpers.sh"
}

stub() {  # <name> <body>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$WORK/bin/$1"
    chmod +x "$WORK/bin/$1"
}

@test "scratch sizing follows the image instead of a fixed 20G" {
    load_helpers
    [ "$(scratch_need_gib "$DECK_BYTES")" -eq 27 ]
    [ "$(scratch_need_gib "$BAZZITE_BYTES")" -eq 21 ]
    # Small images and unknown sizes keep the historical 20G floor.
    [ "$(scratch_need_gib $((1 << 30)))" -eq 20 ]
    [ "$(scratch_need_gib "")" -eq 20 ]
    [ "$(scratch_need_gib "garbage")" -eq 20 ]
}

@test "the sized scratch holds a pull's measured peak (staged blobs + unpacked layers)" {
    load_helpers
    local gib=$((1 << 30))
    # deck: 6.29 GiB staged + 14.49 GiB unpacked (4K blocks) = 20.8 GiB
    [ $(( $(scratch_need_gib "$DECK_BYTES") * gib )) -gt $(( DECK_BYTES + 14 * gib + gib / 2 )) ]
    # bazzite: 4.71 + 12.67 = 17.4 GiB
    [ $(( $(scratch_need_gib "$BAZZITE_BYTES") * gib )) -gt $(( BAZZITE_BYTES + 12 * gib + gib * 7 / 10 )) ]
}

@test "the scratch is no longer created at a hard-coded 20G" {
    run grep -nE 'truncate -s 20G' "$DEPLOY"
    [ "$status" -ne 0 ]
    grep -Fq 'truncate -s "${SCRATCH_MIN_GIB}G" "$SCRATCH_IMG"' "$DEPLOY"
}

@test "ensure_scratch_capacity grows the scratch online when the drive has room" {
    load_helpers
    stub skopeo "echo '{\"LayersData\":[{\"Size\":$((DECK_BYTES - 1000))},{\"Size\":1000}]}'"
    stub df 'if [ "$1" = -B1 ]; then echo Avail; echo $((100 << 30)); else echo "Filesystem Size Used Avail"; echo "x 27G 1G 26G"; fi'
    stub losetup 'echo "losetup $*" >> "$CALLS"'
    stub resize2fs 'echo "resize2fs $*" >> "$CALLS"'
    PATH="$WORK/bin:$PATH"
    SCRATCH_IMG="$WORK/scratch.img"; truncate -s 20G "$SCRATCH_IMG"
    SCRATCH_LOOP=/dev/loop9
    IMAGE=ghcr.io/example/big:stable
    run ensure_scratch_capacity "docker://$IMAGE"
    [ "$status" -eq 0 ]
    [ "$(stat -c %s "$SCRATCH_IMG")" -eq $((27 << 30)) ]
    grep -qx 'losetup -c /dev/loop9' "$CALLS"
    grep -qx 'resize2fs /dev/loop9' "$CALLS"
    [[ "$output" == *"needs 27 GiB, have 20 GiB"* ]]
}

@test "ensure_scratch_capacity refuses with the numbers when the drive is too full" {
    load_helpers
    stub skopeo "echo '{\"LayersData\":[{\"Size\":$DECK_BYTES}]}'"
    stub df 'echo Avail; echo $((5 << 30))'
    stub losetup 'echo "losetup $*" >> "$CALLS"'
    stub resize2fs 'echo "resize2fs $*" >> "$CALLS"'
    stub sleep ':'
    PATH="$WORK/bin:$PATH"
    SCRATCH_IMG="$WORK/scratch.img"; truncate -s 20G "$SCRATCH_IMG"
    SCRATCH_LOOP=/dev/loop9
    IMAGE=ghcr.io/example/big:stable
    DEBUG=""
    run ensure_scratch_capacity "docker://$IMAGE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs about 27 GiB of temporary space"* ]]
    [[ "$output" == *"only 5 GiB free"* ]]
    grep -q '^SPLASH Not enough free space' "$CALLS"
    # Nothing was resized, and the scratch file was left alone.
    ! grep -q resize2fs "$CALLS"
    [ "$(stat -c %s "$SCRATCH_IMG")" -eq $((20 << 30)) ]
}

@test "ensure_scratch_capacity leaves a big-enough scratch and an unreadable size alone" {
    load_helpers
    stub losetup 'echo "losetup $*" >> "$CALLS"'
    stub resize2fs 'echo "resize2fs $*" >> "$CALLS"'
    stub df 'echo Avail; echo $((100 << 30))'
    PATH="$WORK/bin:$PATH"
    SCRATCH_IMG="$WORK/scratch.img"; truncate -s 20G "$SCRATCH_IMG"
    SCRATCH_LOOP=/dev/loop9
    IMAGE=ghcr.io/example/small:stable

    stub skopeo "echo '{\"LayersData\":[{\"Size\":$((2 << 30))}]}'"
    run ensure_scratch_capacity "docker://$IMAGE"
    [ "$status" -eq 0 ]

    stub skopeo 'exit 1'
    run ensure_scratch_capacity "docker://$IMAGE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not read the size"* ]]

    [ ! -s "$CALLS" ]
    [ "$(stat -c %s "$SCRATCH_IMG")" -eq $((20 << 30)) ]
}

@test "acquire_image skips the pull when the image is already local" {
    load_helpers
    stub podman 'echo "podman $*" >> "$CALLS"; [ "$1 $2" = "image exists" ]'
    PATH="$WORK/bin:$PATH"
    IMAGE=ghcr.io/example/img:stable
    run acquire_image "backend probe"
    [ "$status" -eq 0 ]
    ! grep -q 'podman pull' "$CALLS"
}

@test "acquire_image retries a transient failure and logs podman's own reason" {
    load_helpers
    stub podman '
echo "podman $*" >> "$CALLS"
[ "$1" = pull ] || exit 1
n=$(grep -c "^podman pull" "$CALLS")
[ "$n" -ge 2 ] && exit 0
echo "Error: initializing source: connection reset by peer" >&2; exit 125'
    stub sleep ':'
    PATH="$WORK/bin:$PATH"
    TMPDIR="$WORK"
    IMAGE=ghcr.io/example/img:stable
    run acquire_image "ntfs-3g injection"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^podman pull' "$CALLS")" -eq 2 ]
    [[ "$output" == *"ntfs-3g injection: pulling ghcr.io/example/img:stable first"* ]]
    [[ "$output" == *"connection reset by peer"* ]]
}

@test "acquire_image stops the deploy on a full scratch instead of pulling again and again" {
    load_helpers
    stub podman '
echo "podman $*" >> "$CALLS"
[ "$1" = pull ] || exit 1
echo "Error: writing blob: adding layer with blob \"sha256:dd7c\": write /var/lib/containers/storage/overlay/x: no space left on device" >&2
exit 125'
    stub df 'echo "Filesystem Size Used Avail"; echo "x 20G 20G 0"'
    stub sleep ':'
    PATH="$WORK/bin:$PATH"
    TMPDIR="$WORK"
    IMAGE=ghcr.io/example/big:stable
    DEBUG=""
    run acquire_image "ntfs-3g injection"
    [ "$status" -eq 1 ]
    # Resumable retries first (podman keeps unpacked layers) — then a FAIL that
    # names the disk, not the network.
    [ "$(grep -c '^podman pull' "$CALLS")" -eq 3 ]
    [[ "$output" == *"no space left on device"* ]]
    [[ "$output" == *"does not fit in the deployer's scratch"* ]]
    [[ "$output" != *"network/registry"* ]]
    grep -q '^SPLASH Not enough free space' "$CALLS"
}

@test "every deployer pull keeps podman's stderr and goes through acquire_image" {
    # The discarded stderr is what made a full disk read as a registry problem.
    run grep -nE 'podman pull[^|]*2>&1' "$DEPLOY"
    [ "$status" -ne 0 ]
    [ "$(grep -c 'podman pull "\$IMAGE"' "$DEPLOY")" -eq 1 ]
    grep -q 'acquire_image "ntfs-3g injection"' "$DEPLOY"
    grep -q 'acquire_image "backend probe"' "$DEPLOY"
    grep -q 'acquire_image "btrfs preflight"' "$DEPLOY"
}

@test "the scratch is sized before the first pull on both the network and the bundle paths" {
    local size_net first_pull size_bundle ingest
    size_net=$(grep -n 'ensure_scratch_capacity "docker://${IMAGE}"' "$DEPLOY" | head -1 | cut -d: -f1)
    first_pull=$(grep -n 'acquire_image "' "$DEPLOY" | grep -v '^[0-9]*:acquire_image()' | head -1 | cut -d: -f1)
    size_bundle=$(grep -n 'ensure_scratch_capacity "oci:${BUNDLE_OCI}"' "$DEPLOY" | head -1 | cut -d: -f1)
    ingest=$(grep -n 'wootc_bundle_ingest /mnt/ntfs/wootc/bundle' "$DEPLOY" | head -1 | cut -d: -f1)
    [ -n "$size_net" ] && [ -n "$first_pull" ] && [ -n "$size_bundle" ] && [ -n "$ingest" ]
    [ "$size_net" -lt "$first_pull" ]
    [ "$size_bundle" -lt "$ingest" ]
    # And after the scratch is mounted (the loop device must exist to grow).
    mount_line=$(grep -n '^mount "\$SCRATCH_LOOP" /var/fisherman-tmp' "$DEPLOY" | cut -d: -f1)
    [ "$mount_line" -lt "$size_bundle" ]
}

@test "the initramfs ships resize2fs for the online grow" {
    grep -Eq '^\s+mkfs\.ext4 resize2fs ' "$REPO_ROOT/payload/deployer/module-setup.sh"
    grep -Eq '^RUN for bin in .*resize2fs' "$REPO_ROOT/payload/deployer/Containerfile"
}
