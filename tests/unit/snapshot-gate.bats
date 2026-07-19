#!/usr/bin/env bats
# snapshot-gate.bats — the pre-deployer snapshot is OFF by default.
#
# It is a fast-retry convenience that currently costs far more than it gives,
# and is the leading suspect for the Phase-2 NTFS failures:
#
#   1. Nothing reads it. `data.qcow2.snap` is written by
#      snapshot_before_deployer() and referenced nowhere else — there is no
#      restore path in the harness at all.
#   2. The design assumed an instant CoW reflink, but `cp --reflink=always`
#      FAILS on every runner (observed on all three), falling back to a full
#      byte copy of an 18-28 GiB qcow2: 10-20+ minutes.
#   3. The guest stays fsfreeze-FROZEN for that entire copy. Windows VSS
#      enforces hard freeze limits (~10s writers, ~60s overall), so a
#      20-minute freeze cannot be honoured — the guest auto-thaws mid-copy and
#      the snapshot is not crash-consistent anyway.
#   4. An NTFS frozen and abruptly thawed can be left DIRTY, and a dirty NTFS
#      cannot be mounted read-write by ntfs3 — precisely the observed Phase-2
#      failure ("root.disk never attached").
#   5. ~28 GiB per run, which is what kept exhausting runner disks.
#
# The barrier release is the subtle part: the Windows OEM wrapper blocks on
# C:\OEM\e2e-snapshot-complete.txt, so skipping the snapshot MUST still mark it
# complete or the run wedges forever waiting for a snapshot that never happens.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
}

@test "run-e2e.sh is syntactically valid" {
    run bash -n "$E2E"
    [ "$status" -eq 0 ]
}

@test "the snapshot is disabled by default" {
    grep -q 'WOOTC_E2E_SNAPSHOT="${WOOTC_E2E_SNAPSHOT:-0}"' "$E2E"
}

@test "the skip path still releases the OEM barrier" {
    # Without this the Windows wrapper waits forever on
    # C:\OEM\e2e-snapshot-complete.txt and the whole run wedges.
    local body
    body=$(sed -n '/if \[ "\$WOOTC_E2E_SNAPSHOT" != "1" \]/,/^    fi$/p' "$E2E")
    [ -n "$body" ]
    echo "$body" | grep -q 'mark_snapshot_complete'
    echo "$body" | grep -q 'return 0'
}

@test "the skip happens BEFORE any freeze or copy" {
    # Freezing the guest is the harmful part; the gate must precede it.
    local gate_line freeze_line
    gate_line=$(grep -n 'WOOTC_E2E_SNAPSHOT" != "1"' "$E2E" | head -1 | cut -d: -f1)
    freeze_line=$(grep -n 'qga_call freeze' "$E2E" | head -1 | cut -d: -f1)
    [ -n "$gate_line" ]
    [ -n "$freeze_line" ]
    [ "$gate_line" -lt "$freeze_line" ]
}

@test "the skip is announced, not silent" {
    # A silently-skipped step is how we end up debugging its absence later.
    grep -q 'Pre-deployer snapshot disabled' "$E2E"
}

@test "it can still be re-enabled explicitly" {
    grep -q 'WOOTC_E2E_SNAPSHOT=1 to enable' "$E2E"
}

@test "there is still no restore path — the snapshot remains write-only" {
    # If someone adds a restore, this test should fail and the default flipped
    # back on deliberately. Until then, keeping it off is strictly correct.
    local refs
    refs=$(grep -c 'data\.qcow2\.snap' "$E2E")
    # only the local vars + tmp name inside snapshot_before_deployer
    [ "$refs" -le 4 ]
}
