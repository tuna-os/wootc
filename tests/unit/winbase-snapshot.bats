#!/usr/bin/env bats
# winbase-snapshot.bats — the GHCR/ORAS pre-installed Windows base image.
#
# Why this suite exists: reinstalling Windows (~20-30 min) before every hosted
# E2E is the dominant fixed cost, and it sits directly in front of the Phase-2
# boot we are trying to validate. The fix is to prime a pristine, cleanly-shut-
# down Windows once, push it to GHCR, and restore it via the existing
# --skip-install path. Two properties, if silently broken by a refactor, produce
# a base image that looks fine and fails only on a later restore run — the most
# expensive possible failure mode. Pin them statically.
#
#   1. The captured image must be a CLEAN shutdown, not a live fsfreeze copy: a
#      frozen-then-thawed NTFS keeps its dirty bit set, which is the exact enemy
#      of the Phase-2 loop attach.
#   2. QEMU must fully exit before qemu-img touches the qcow2, or the image is
#      subtly corrupt.
#   3. The restore is a pure speedup: a key mismatch must fall back to a full
#      install, never fail the run.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
    PRIME_WF="$REPO_ROOT/.github/workflows/e2e-snapshot.yml"
    HOSTED_WF="$REPO_ROOT/.github/workflows/e2e-hosted.yml"
}

# ── capture side (prime) ─────────────────────────────────────────────────────

@test "run-e2e.sh is syntactically valid" {
    run bash -n "$E2E"
    [ "$status" -eq 0 ]
}

@test "the capture point is BEFORE any OEM/migration setup runs" {
    # The whole value of the base image is that it is pre-migration and thus
    # image- and code-agnostic. Capturing after setup would bake a specific
    # target image / deployer into the disk and collapse the cache hit rate.
    local out_line oem_line
    out_line=$(grep -n 'WOOTC_E2E_SNAPSHOT_OUT:-' "$E2E" | tail -1 | cut -d: -f1)
    oem_line=$(grep -n 'Starting OEM setup' "$E2E" | head -1 | cut -d: -f1)
    [ -n "$out_line" ] && [ -n "$oem_line" ]
    [ "$out_line" -lt "$oem_line" ]
}

@test "prime captures via a CLEAN shutdown, never a live fsfreeze" {
    # Clean shutdown clears the NTFS dirty bit; fsfreeze/thaw sets it.
    grep -q 'Stop-Computer -Force' "$E2E"
    # The prime block must not reach for the freeze path.
    run bash -c "sed -n '/WOOTC_E2E_SNAPSHOT_OUT:-/,/^fi\$/p' '$E2E' | grep -c 'qga_call freeze'"
    [ "$output" -eq 0 ]
}

@test "prime waits for the guest to power off before converting" {
    # qga_windows_probe going away == QEMU is exiting; converting a qcow2 QEMU
    # still holds open yields a corrupt image.
    grep -q 'qga_windows_probe || break' "$E2E"
}

@test "prime brings the container down before qemu-img convert" {
    local down_line convert_line
    down_line=$(grep -n 'compose.yml down' "$E2E" | tail -1 | cut -d: -f1)
    convert_line=$(grep -n 'qemu-img convert -c' "$E2E" | head -1 | cut -d: -f1)
    [ -n "$down_line" ] && [ -n "$convert_line" ]
    [ "$down_line" -lt "$convert_line" ]
}

@test "prime produces a compressed, standalone qcow2" {
    # -c compresses; convert (not cp) flattens any backing chain into one image.
    grep -q 'qemu-img convert -c -O qcow2' "$E2E"
}

@test "prime refuses to combine with --skip-install" {
    # Priming from a reused disk would capture a non-pristine, possibly migrated
    # state. It must demand a fresh install.
    grep -q 'WOOTC_E2E_SNAPSHOT_OUT needs a fresh install' "$E2E"
}

@test "prime writes the correctness key AND dockur's install markers" {
    grep -q 'snapshot.key' "$E2E"
    grep -q '\.wootc-autounattend\.sha256' "$E2E"
    grep -q 'STORAGE_DIR"/windows\.\*' "$E2E"
}

# ── restore side ─────────────────────────────────────────────────────────────

@test "restore keys on the SAME formula as ANSWER_SHA (folds in bitlocker)" {
    # ANSWER_SHA hashes the rendered answer file + WIN_VERSION, and the answer
    # file is already mutated by the BitLocker axis. The restore key must use the
    # identical derivation or a valid image would be wrongly rejected/accepted.
    local canon
    canon='sha256sum < "$RENDERED_ANSWER"; echo "$WIN_VERSION"; } | sha256sum'
    # ANSWER_SHA derivation and the restore/prime key derivation must match.
    run grep -c "$canon" "$E2E"
    [ "$output" -ge 3 ]   # ANSWER_SHA (x2 paths) + restore + prime
}

@test "a key MISMATCH falls back to a full install, never fails the run" {
    # The snapshot is a speedup, not a correctness dependency.
    grep -q 'doing a full install' "$E2E"
    # No `exit 1` inside the restore decision on a mismatch.
    run bash -c "sed -n '/restore a pristine Windows base image/,/^if \[ \"\$SKIP_INSTALL\" = false \]/p' '$E2E' | grep -c 'exit 1'"
    [ "$output" -eq 0 ]
}

@test "a successful restore forces the --skip-install reuse path" {
    # The restore-block assignment (bare, indented) — distinct from the
    # flag-parse `--skip-install) SKIP_INSTALL=true` earlier in the file.
    grep -qE '^\s+SKIP_INSTALL=true$' "$E2E"
    # And it must set that only after validating the key (inside the have==want
    # branch), i.e. the assignment follows the key comparison.
    local cmp_line set_line
    cmp_line=$(grep -n 'have_key" = "$want_key' "$E2E" | head -1 | cut -d: -f1)
    set_line=$(grep -nE '^\s+SKIP_INSTALL=true$' "$E2E" | head -1 | cut -d: -f1)
    [ "$cmp_line" -lt "$set_line" ]
}

# ── CI wiring ────────────────────────────────────────────────────────────────

@test "the hosted E2E pull is best-effort (a cache miss never gates a run)" {
    grep -q 'continue-on-error: true' "$HOSTED_WF"
    grep -q 'WOOTC_E2E_SNAPSHOT_IN=/mnt/wootc-snapshot' "$HOSTED_WF"
}

@test "the prime workflow pushes to a per-axis GHCR tag via ORAS" {
    grep -q 'wootc-winbase' "$PRIME_WF"
    grep -q 'oras push' "$PRIME_WF"
    grep -q 'bl-' "$PRIME_WF"          # tag folds in the bitlocker axis
    grep -q 'packages: write' "$PRIME_WF"
}

@test "the hosted workflow has packages:read to pull the base image" {
    grep -q 'packages: read' "$HOSTED_WF"
}
