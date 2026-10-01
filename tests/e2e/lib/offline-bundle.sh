# shellcheck shell=bash
# Offline axis (--offline, #217): the guest VM has no network device at all,
# and the deployer must install from a pre-staged OCI bundle. Sourcing defines
# functions; it does no work.
#
# The bundle has the exact shape the app's pre-download writes
# (app/ocipull.go stageImageBundle) and the deployer validates
# (payload/deployer/offline-bundle.sh wootc_bundle_validate):
#   <dir>/bundle.json           {"image","digest","storeBytes","createdAt","source"}
#   <dir>/oci/oci-layout        {"imageLayoutVersion":"1.0.0"}
#   <dir>/oci/index.json        exactly one linux/amd64 image manifest
#   <dir>/oci/blobs/sha256/...

# wootc_offline_make_bundle <image-ref> <bundle-dir>
# Copy one linux/amd64 manifest of <image-ref> into <bundle-dir>/oci and write
# bundle.json beside it. Uses host skopeo, or the skopeo container when the
# host has none. Prints the manifest digest on success.
wootc_offline_make_bundle() {
    local image="$1" dir="$2" digest bytes
    [ -n "$image" ] && [ -n "$dir" ] || return 2
    rm -rf -- "$dir" || return 1
    mkdir -p "$dir" || return 1
    if command -v skopeo >/dev/null 2>&1; then
        skopeo copy --retry-times 3 --override-os linux --override-arch amd64 \
            "docker://$image" "oci:$dir/oci" >&2 || return 1
    else
        "${DOCKER:-podman}" run --rm -v "$dir:/bundle:Z" quay.io/skopeo/stable:latest \
            copy --retry-times 3 --override-os linux --override-arch amd64 \
            "docker://$image" "oci:/bundle/oci" >&2 || return 1
    fi
    # The deployer refuses an index that holds anything but the one manifest
    # it will verify and install. Check here so a bad copy fails on the host
    # with a clear message, not 40 minutes later as a network fallback.
    digest=$(jq -er '.manifests | if length == 1 then .[0].digest else error("manifests=\(length)") end' \
        "$dir/oci/index.json") || return 1
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    bytes=$(find "$dir/oci" -type f -printf '%s\n' | awk '{n += $1} END {print n + 0}') || return 1
    jq -n --arg image "$image" --arg digest "$digest" --argjson bytes "$bytes" \
        --arg created "$(date -u +%FT%TZ)" \
        '{image: $image, digest: $digest, storeBytes: $bytes, createdAt: $created, source: "predownload"}' \
        > "$dir/bundle.json" || return 1
    printf '%s\n' "$digest"
}

# wootc_offline_qemu_has_no_nic <qemu-cmdline>
# The proof that the guest is offline is the QEMU command line itself: no
# -netdev, no -nic other than "none", and no network -device. A missing
# network is what the axis asserts, so read it from the running process, not
# from the compose setting that should have caused it.
wootc_offline_qemu_has_no_nic() {
    local cmdline="$1"
    [ -n "$cmdline" ] || return 1
    case " $cmdline " in
        *" -netdev "*) return 1 ;;
        *" -nic none "*) ;;
        *" -nic "*) return 1 ;;
    esac
    if printf '%s\n' "$cmdline" | grep -qE -- '-device[ =]+(virtio-net|e1000|rtl8139|vmxnet3|ne2k)'; then
        return 1
    fi
    return 0
}

# wootc_offline_check_serial <serial-log> <image-ref>
# Hold the deployer to the offline contract from its own serial lines. Prints
# one line per finding; returns non-zero when any part of the contract is
# missing. The lines come from payload/deployer/deploy.sh.
wootc_offline_check_serial() {
    local log="$1" image="$2" rc=0
    [ -r "$log" ] || { echo "MISSING serial log $log"; return 1; }
    if grep -aqF "Offline bundle for ${image} found" "$log"; then
        echo "OK bundle found for $image"
    else
        echo "MISSING deployer did not find the bundle for $image"; rc=1
    fi
    if grep -aqF "[PASS] bundle bytes and imported image verified for ${image}" "$log"; then
        echo "OK bundle ingested and verified"
    else
        echo "MISSING bundle ingest did not verify"; rc=1
    fi
    if grep -aqF "Registry pre-flight skipped" "$log"; then
        echo "OK registry pre-flight skipped"
    else
        echo "MISSING registry pre-flight was not skipped"; rc=1
    fi
    if grep -aqE "bundle ingest failed|Bundle holds .* not " "$log"; then
        echo "BAD deployer rejected the bundle"; rc=1
    fi
    return "$rc"
}
