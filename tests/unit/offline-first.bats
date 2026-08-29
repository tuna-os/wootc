#!/usr/bin/env bats
# Offline-first deploy contracts (docs/branding-and-distribution.md §3):
# Windows does all networking; the deployer must be able to do none. A
# laptop's Wi-Fi does not exist in the initramfs — the E2E VM's virtio
# ethernet has been masking that — so every network dependency in the deploy
# stage is a bug, and these pin the pieces that remove them.

DEPLOY="payload/deployer/deploy.sh"
MODSETUP="payload/deployer/module-setup.sh"
HOOK="payload/deployer/deploy-hook.sh"

@test "the deploy hook fires without a network (settled + online, one guard)" {
    # initqueue/online never runs on an offline machine; the same hook at
    # initqueue/settled starts the deployer anyway, and the run-once guard
    # keeps the two instances from double-starting.
    grep -q 'initqueue/online/99-wootc-deploy.sh' "$MODSETUP"
    grep -q 'initqueue/settled/99-wootc-deploy.sh' "$MODSETUP"
    grep -q 'guard=/run/wootc-deployer-started' "$HOOK"
    grep -q '\[ -e "$guard" \] && return 0' "$HOOK"
}

@test "a staged OCI bundle is ingested before anything network-shaped runs" {
    # The ingest must come BEFORE the registry preflight in the script, so an
    # offline deploy never reaches a step that assumes a network.
    ingest_line=$(grep -n 'Offline bundle ingest' "$DEPLOY" | head -1 | cut -d: -f1)
    preflight_line=$(grep -n 'phase "registry-preflight"' "$DEPLOY" | head -1 | cut -d: -f1)
    [ -n "$ingest_line" ] && [ -n "$preflight_line" ]
    [ "$ingest_line" -lt "$preflight_line" ]
    # Plain-file OCI layout on NTFS, matched against the user's selection,
    # ingested into local storage so probes + fisherman run network-free.
    grep -q 'BUNDLE_OCI="/mnt/ntfs/wootc/bundle/oci"' "$DEPLOY"
    grep -q 'podman pull -q "oci:${BUNDLE_OCI}"' "$DEPLOY"
    grep -q 'podman tag "$_iid" "$IMAGE"' "$DEPLOY"
    # Best-effort: a broken bundle degrades to the network, never a dead PC.
    grep -q 'bundle ingest failed' "$DEPLOY"
}

@test "with a bundle, the registry preflight is skipped; without one, the wait is bounded and names the fix" {
    grep -q 'Registry pre-flight skipped' "$DEPLOY"
    # No bundle + no network → a bounded wait with a user-facing message that
    # says what to actually do (wired cable / reinstall with pre-download),
    # then a truthful splash before returning to Windows.
    grep -q 'phase "network-wait"' "$DEPLOY"
    grep -q '_net_waited >= 300' "$DEPLOY"
    grep -q 'Connect a network cable and try again' "$DEPLOY"
    grep -q 'No internet connection. Restarting into Windows' "$DEPLOY"
}

@test "offline deploys skip the dnf injection instead of burning its timeouts" {
    grep -q 'offline: skipping ntfs-3g injection' "$DEPLOY"
    # And the skip is the WARN-not-FAIL kind: injection is best-effort belt,
    # the staged closure + runtime fallback are the offline answer.
    run grep '\[FAIL\].*offline' "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "the app pre-downloads with fail-closed digest verification" {
    # The Windows-side puller writes the OCI layout the deployer ingests, and
    # every blob is refused on digest mismatch — the download IS the
    # verification.
    grep -q 'refusing corrupted or tampered content' app/ocipull.go
    grep -q 'refusing tampered content' app/ocipull.go
    grep -q '"Downloading your Linux system"' app/app.go
    grep -q "'Downloading your Linux system'" app/frontend/src/screens/progress.js
    # A pre-downloaded bundle records its provenance so it never pins the
    # catalog the way a shipped bundle does (#177).
    grep -q '"predownload"' app/ocipull.go
    # Package-wide: the guard's file is a layout choice, its presence is not.
    grep -q 'b.Source != "predownload"' app/*.go
}
