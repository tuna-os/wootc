#!/usr/bin/env bats
# offline-axis.bats — the offline matrix axis (#217) must prove offline from
# observables: the QEMU argv has no NIC, the bundle has the shape the deployer
# validates, and the deployer's own serial lines show it used the bundle.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    MATRIX="$REPO_ROOT/tests/e2e/matrix.tsv"
    RUNNER="$REPO_ROOT/tests/e2e/run-matrix.sh"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
    source "$REPO_ROOT/tests/e2e/lib/offline-bundle.sh"
    IMAGE=ghcr.io/tuna-os/yellowfin:gnome
}

# A deployer serial log for the given outcome.
serial() {
    local log="$BATS_TEST_TMPDIR/serial.log"
    case "$1" in
        offline)
            printf '%s\n' \
                "[wootc] Offline bundle for $IMAGE found — ingesting the OCI layout (no network needed)..." \
                "[wootc]   [PASS] bundle bytes and imported image verified for $IMAGE" \
                "[wootc] Registry pre-flight skipped — $IMAGE is already local (offline bundle)" ;;
        fallback)
            printf '%s\n' \
                "[wootc] Offline bundle for $IMAGE found — ingesting the OCI layout (no network needed)..." \
                "[wootc]   [WARN] bundle ingest failed — falling back to the network" ;;
        online)
            printf '%s\n' "[wootc] phase: registry-preflight" ;;
    esac > "$log"
    echo "$log"
}

@test "no-NIC check accepts a QEMU argv without a network device" {
    run wootc_offline_qemu_has_no_nic "qemu-system-x86_64 -nodefaults -m 8G -device virtio-serial -drive file=/storage/data.qcow2"
    [ "$status" -eq 0 ]
    run wootc_offline_qemu_has_no_nic "qemu-system-x86_64 -nodefaults -nic none -m 8G"
    [ "$status" -eq 0 ]
}

@test "no-NIC check refuses any network device in the QEMU argv" {
    run wootc_offline_qemu_has_no_nic "qemu-system-x86_64 -netdev tap,id=hostnet0,ifname=qemu -device virtio-net-pci,id=net0,netdev=hostnet0"
    [ "$status" -ne 0 ]
    run wootc_offline_qemu_has_no_nic "qemu-system-x86_64 -nic user,model=e1000"
    [ "$status" -ne 0 ]
    run wootc_offline_qemu_has_no_nic "qemu-system-x86_64 -device e1000,id=net0"
    [ "$status" -ne 0 ]
}

@test "no-NIC check refuses an empty argv instead of passing on nothing" {
    run wootc_offline_qemu_has_no_nic ""
    [ "$status" -ne 0 ]
}

@test "serial check passes only when the deployer ingested the bundle" {
    run wootc_offline_check_serial "$(serial offline)" "$IMAGE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK bundle ingested and verified"* ]]
}

@test "serial check fails a deploy that fell back to the network" {
    run wootc_offline_check_serial "$(serial fallback)" "$IMAGE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"BAD deployer rejected the bundle"* ]]
}

@test "serial check fails a deploy that never saw a bundle" {
    run wootc_offline_check_serial "$(serial online)" "$IMAGE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MISSING deployer did not find the bundle"* ]]
}

@test "serial check fails for a bundle of a different image" {
    run wootc_offline_check_serial "$(serial offline)" ghcr.io/tuna-os/bonito:gnome
    [ "$status" -ne 0 ]
}

@test "serial check strings match what the deployer prints" {
    deploy="$REPO_ROOT/payload/deployer/deploy.sh"
    grep -qF 'Offline bundle for ${IMAGE} found' "$deploy"
    grep -qF '[PASS] bundle bytes and imported image verified for ${IMAGE}' "$deploy"
    grep -qF 'Registry pre-flight skipped' "$deploy"
    grep -qF 'bundle ingest failed' "$deploy"
}

@test "bundle builder writes the layout the deployer validates" {
    # Stub skopeo: write a one-manifest OCI layout as `skopeo copy` would.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/skopeo" <<'EOF'
#!/usr/bin/env bash
dest="${@: -1}"; dest="${dest#oci:}"
mkdir -p "$dest/blobs/sha256"
printf '{"schemaVersion":2}' > "$dest/blobs/sha256/manifest"
d=sha256:$(printf '%064d' 7)
printf '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","size":19}]}' "$d" > "$dest/index.json"
printf '{"imageLayoutVersion":"1.0.0"}' > "$dest/oci-layout"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/skopeo"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run wootc_offline_make_bundle "$IMAGE" "$BATS_TEST_TMPDIR/bundle"
    [ "$status" -eq 0 ]
    [ "$output" = "sha256:$(printf '%064d' 7)" ]
    jq -e --arg i "$IMAGE" --arg d "$output" \
        '.image == $i and .digest == $d and .source == "predownload" and .storeBytes > 0' \
        "$BATS_TEST_TMPDIR/bundle/bundle.json"
}

@test "bundle builder refuses an index with more than one manifest" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/skopeo" <<'EOF'
#!/usr/bin/env bash
dest="${@: -1}"; dest="${dest#oci:}"
mkdir -p "$dest"
d=sha256:$(printf '%064d' 7)
printf '{"manifests":[{"digest":"%s"},{"digest":"%s"}]}' "$d" "$d" > "$dest/index.json"
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/skopeo"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run wootc_offline_make_bundle "$IMAGE" "$BATS_TEST_TMPDIR/bundle"
    [ "$status" -ne 0 ]
    [ ! -f "$BATS_TEST_TMPDIR/bundle/bundle.json" ]
}

@test "matrix carries an offline smoke cell on the script path" {
    grep -v '^#' "$MATRIX" | grep -P '^smoke\t' | grep -q 'offline=on'
}

@test "offline=on translates to --offline on the remote invocation" {
    grep -q 'offline=on\*) echo .--offline.' "$RUNNER"
}

@test "run-e2e.sh refuses --offline with --gui-install" {
    grep -q -- '--offline cannot combine with --gui-install' "$E2E"
}

@test "compose passes the guest network switch to Dockur" {
    grep -q 'NETWORK: "${WOOTC_E2E_GUEST_NETWORK:-Y}"' "$REPO_ROOT/tests/e2e/compose.yml"
}
