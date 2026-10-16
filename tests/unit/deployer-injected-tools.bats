#!/usr/bin/env bats
#
# The deployer's look inside the target image must tell "the tool is absent"
# apart from "the probe could not run".
#
# Runs 38792319332 (bazzite:stable, passed) and 38832644743 (bazzite-deck:stable)
# both logged
#     [WARN] ntfs-3g or qemu-guest-agent still absent from
#            localhost/wootc-ntfs-injected:latest after injection
# although both images ship /usr/bin/ntfs-3g and /usr/bin/qemu-ga: their
# published layers carry both files, and the rpmdb lists both packages. The two
# failing probes were the only `podman run`s in the deployer without
# --network=host, and the first one ran before the image was pulled, inside a
# 60s bound. It failed, so injection ran on an image that already had ntfs-3g,
# and the verify probe failed in the same way.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    WORK="$(mktemp -d)"
    mkdir -p "$WORK/bin"
    export CALLS="$WORK/calls"
    : > "$CALLS"
    export TMPDIR="$WORK"
    export PATH="$WORK/bin:$PATH"
    export IMAGE="localhost/wootc-ntfs-injected:latest"
}

teardown() {
    rm -rf "$WORK"
}

load_helpers() {
    {
        echo 'log() { echo "LOG $*"; }'
        echo 'err() { echo "ERR $*"; }'
        # The probe strings and PROBE_ERR are top-level assignments; the
        # INJECTED_TOOLS_PROBE one spans lines up to its closing quote.
        sed -n "/^NTFS_DRIVER_PROBE='/,/'\$/p" "$DEPLOY"
        sed -n "/^INJECTED_TOOLS_PROBE='/,/'\$/p" "$DEPLOY"
        sed -n '/^PROBE_ERR=/p' "$DEPLOY"
        for fn in probe_image verify_injected_tools; do
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

@test "image probes run with --network=host, like every probe that works in the initramfs" {
    load_helpers
    stub_podman 'exit 0'
    probe_image 'true'
    grep -q -- 'podman run --rm --network=host localhost/wootc-ntfs-injected:latest sh -c true' "$CALLS"
}

@test "the NTFS section has no podman run on \$IMAGE without --network=host" {
    # The two that did are the two that failed on the bazzite images.
    section="$(sed -n '/^# ── Ensure the image can mount NTFS at Phase-2 boot/,/^# ── Resolve deployment backend/p' "$DEPLOY")"
    [ -n "$section" ]
    run grep -nE 'podman run --rm "\$IMAGE"' <<< "$section"
    [ "$status" -ne 0 ]
    run grep -nE 'timeout 60 podman run' <<< "$section"
    [ "$status" -ne 0 ]
}

@test "the NTFS probe pulls the image before it probes (not inside a 60s bound)" {
    body="$(sed -n '/^ensure_ntfs_support() {/,/^}/p' "$DEPLOY")"
    acquire=$(printf '%s\n' "$body" | grep -n 'acquire_image "NTFS probe"' | head -1 | cut -d: -f1)
    probe=$(printf '%s\n' "$body" | grep -n 'probe_image "\$NTFS_DRIVER_PROBE"' | head -1 | cut -d: -f1)
    [ -n "$acquire" ] && [ -n "$probe" ]
    [ "$acquire" -lt "$probe" ]
}

@test "the fallback check runs the same NTFS capability test as the first probe" {
    [ "$(grep -c 'probe_image "\$NTFS_DRIVER_PROBE"' "$DEPLOY")" -eq 2 ]
}

@test "verify passes and logs the resolved paths, including one off PATH" {
    load_helpers
    stub_podman 'printf "ntfs-3g=/usr/bin/ntfs-3g\nqemu-ga=/usr/libexec/qemu-ga\nrpm=ntfs-3g-2026.2.25 qemu-guest-agent-11.1.2\n"'
    run verify_injected_tools
    [ "$status" -eq 0 ]
    [[ "$output" == *"[PASS]"* ]]
    [[ "$output" == *"qemu-ga=/usr/libexec/qemu-ga"* ]]
    [[ "$output" == *"ntfs-3g=/usr/bin/ntfs-3g"* ]]
}

@test "verify names the missing tool and the rpmdb view on ONE [WARN] line" {
    load_helpers
    stub_podman 'printf "ntfs-3g=/usr/bin/ntfs-3g\nqemu-ga=ABSENT\nrpm=package qemu-guest-agent is not installed\n"'
    run verify_injected_tools
    [ "$status" -eq 1 ]
    warn=$(printf '%s\n' "$output" | grep '\[WARN\]')
    [ "$(printf '%s\n' "$warn" | wc -l)" -eq 1 ]
    [[ "$warn" == *"qemu-ga=ABSENT"* ]]
    [[ "$warn" == *"qemu-guest-agent is not installed"* ]]
}

@test "a probe that cannot run is reported as that, with podman's stderr, not as absent" {
    load_helpers
    stub_podman 'echo "Error: netavark: nftables error: nft did not return successfully" >&2; exit 125'
    run verify_injected_tools
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not inspect"* ]]
    [[ "$output" == *"probe exit 125"* ]]
    [[ "$output" == *"netavark: nftables error"* ]]
    [[ "$output" != *"still absent"* ]]
}

@test "the in-image probe resolves tools on PATH and reports the rest as ABSENT" {
    load_helpers
    for d in /usr/bin /usr/sbin /usr/libexec /usr/local/bin /usr/local/sbin; do
        [ -x "$d/qemu-ga" ] && skip "this host ships $d/qemu-ga"
    done
    mkdir -p "$WORK/img"
    printf '#!/bin/sh\n' > "$WORK/img/ntfs-3g"
    chmod +x "$WORK/img/ntfs-3g"
    run env PATH="$WORK/img:/usr/bin:/bin" sh -c "$INJECTED_TOOLS_PROBE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ntfs-3g=$WORK/img/ntfs-3g"* ]]
    [[ "$output" == *"qemu-ga=ABSENT"* ]]
    printf '#!/bin/sh\n' > "$WORK/img/qemu-ga"
    chmod +x "$WORK/img/qemu-ga"
    run env PATH="$WORK/img:/usr/bin:/bin" sh -c "$INJECTED_TOOLS_PROBE"
    [[ "$output" == *"qemu-ga=$WORK/img/qemu-ga"* ]]
}

@test "injection logs the install output on success, so the winning rung is visible" {
    body="$(sed -n '/^ensure_ntfs_support() {/,/^}/p' "$DEPLOY")"
    printf '%s\n' "$body" | grep -q 'injection output (tail):'
    printf '%s\n' "$body" | grep -q 'injection stderr (tail):'
    printf '%s\n' "$body" | grep -q '^    verify_injected_tools$'
}
