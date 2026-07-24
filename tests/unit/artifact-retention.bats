#!/usr/bin/env bats
# artifact-retention.bats — the harness must not fill the disk it runs on.
#
# Every run writes a full artifact set (container logs, screenshots, video,
# serial capture) — 3.3 GiB for a single run in practice. Nothing ever removed
# them, so runners filled silently until a LATER run died at the preflight:
#
#   [FAIL] Only 57 GiB free under .../tests/e2e/storage; need at least 65 GiB
#
# A harness that breaks the next run by succeeding is not finished. Retention
# keeps the N newest run directories, but always preserves the small text
# evidence (serial + logs) from pruned runs — that is what failures get
# diagnosed from days later, and it costs kilobytes. The bulk (video, disk
# images, container dumps) is what actually consumes space.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
    STORAGE_DIR="$BATS_TEST_TMPDIR/storage"
    mkdir -p "$STORAGE_DIR/artifacts"
    # Source just the retention function.
    eval "$(sed -n '/^WOOTC_E2E_KEEP_RUNS=/,/^}/p' "$E2E")"
}

# Build a fake run dir with a big blob and small evidence.
mkrun() {
    local d="$STORAGE_DIR/artifacts/$1"
    mkdir -p "$d/video"
    echo "serial data for $1" > "$d/qemu.pty"
    echo "log data for $1"    > "$d/e2e.log"
    head -c 1048576 /dev/zero > "$d/video/big.mp4"
    touch -d "$2" "$d"
}

@test "run-e2e.sh is syntactically valid" {
    run bash -n "$E2E"
    [ "$status" -eq 0 ]
}

@test "keeps the N newest runs and prunes the rest" {
    mkrun old1 "2026-07-01" ; mkrun old2 "2026-07-02" ; mkrun old3 "2026-07-03"
    mkrun new1 "2026-07-10" ; mkrun new2 "2026-07-11" ; mkrun new3 "2026-07-12"
    WOOTC_E2E_KEEP_RUNS=3 prune_old_artifacts
    [ -d "$STORAGE_DIR/artifacts/new1" ]
    [ -d "$STORAGE_DIR/artifacts/new2" ]
    [ -d "$STORAGE_DIR/artifacts/new3" ]
    [ ! -d "$STORAGE_DIR/artifacts/old1" ]
    [ ! -d "$STORAGE_DIR/artifacts/old2" ]
    [ ! -d "$STORAGE_DIR/artifacts/old3" ]
}

@test "serial and logs from pruned runs are preserved as evidence" {
    # Losing the serial of a failed run means losing the only record of why it
    # failed — that has already cost real debugging time this project.
    mkrun old1 "2026-07-01"
    mkrun new1 "2026-07-10" ; mkrun new2 "2026-07-11" ; mkrun new3 "2026-07-12"
    WOOTC_E2E_KEEP_RUNS=3 prune_old_artifacts
    [ -f "$STORAGE_DIR/artifacts/.evidence/old1/qemu.pty" ]
    [ -f "$STORAGE_DIR/artifacts/.evidence/old1/e2e.log" ]
    grep -q "serial data for old1" "$STORAGE_DIR/artifacts/.evidence/old1/qemu.pty"
}

@test "the bulk (video) is NOT preserved — that is the point" {
    mkrun old1 "2026-07-01"
    mkrun new1 "2026-07-10" ; mkrun new2 "2026-07-11" ; mkrun new3 "2026-07-12"
    WOOTC_E2E_KEEP_RUNS=3 prune_old_artifacts
    [ ! -e "$STORAGE_DIR/artifacts/.evidence/old1/big.mp4" ]
    [ ! -d "$STORAGE_DIR/artifacts/old1/video" ]
}

@test "the evidence directory is never itself pruned" {
    # It is inside artifacts/, so a naive prune would eat it and destroy every
    # preserved serial log on the third run.
    mkrun old1 "2026-07-01"
    mkrun new1 "2026-07-10" ; mkrun new2 "2026-07-11" ; mkrun new3 "2026-07-12"
    WOOTC_E2E_KEEP_RUNS=3 prune_old_artifacts
    touch -d "2026-06-01" "$STORAGE_DIR/artifacts/.evidence"
    WOOTC_E2E_KEEP_RUNS=1 prune_old_artifacts
    [ -d "$STORAGE_DIR/artifacts/.evidence" ]
    [ -f "$STORAGE_DIR/artifacts/.evidence/old1/qemu.pty" ]
}

@test "an empty or missing artifacts dir is a clean no-op" {
    rm -rf "$STORAGE_DIR/artifacts"
    run prune_old_artifacts
    [ "$status" -eq 0 ]
    mkdir -p "$STORAGE_DIR/artifacts"
    run prune_old_artifacts
    [ "$status" -eq 0 ]
}

@test "fewer runs than the keep count prunes nothing" {
    mkrun only1 "2026-07-10"
    WOOTC_E2E_KEEP_RUNS=3 prune_old_artifacts
    [ -d "$STORAGE_DIR/artifacts/only1" ]
}

@test "retention runs on startup so a run cannot be blocked by its predecessors" {
    # Pruning only at exit would not help: the preflight that fails runs first.
    local prune_line preflight_line
    prune_line=$(grep -n '^prune_old_artifacts$' "$E2E" | head -1 | cut -d: -f1)
    # Match the actual preflight `fail` call, not the comment above the prune
    # function that quotes the same message — the first version of this test
    # matched its own documentation and reported a bug that did not exist.
    preflight_line=$(grep -n 'fail "Only .*GiB free under' "$E2E" | head -1 | cut -d: -f1)
    [ -n "$prune_line" ]
    [ -n "$preflight_line" ]
    [ "$prune_line" -lt "$preflight_line" ]
}

@test "preflight demands headroom for two runs, not the bare minimum for one" {
    # 65 GiB was the minimum to survive ONE run, so a run could pass preflight
    # and still die mid-deploy, leaving nothing for the next run.
    #
    # It was then 120, but that assumed the pre-deployer snapshot's FULL byte
    # copy of data.qcow2. With the snapshot disabled (1c6d713) a run's resident
    # footprint is ~45 GiB, and 120 wrongly REJECTED a GitHub hosted runner
    # (~114 GiB after its cleanup step) — a preflight so strict it excluded the
    # most reliable infrastructure available.
    grep -q 'WOOTC_E2E_MIN_FREE_GIB:-90' "$E2E"
    run grep -n 'required_free_gib=65' "$E2E"
    [ "$status" -ne 0 ]
}

@test "a hosted runner's ~114 GiB clears the requirement" {
    # Regression guard on the specific number that blocked run 29674970326.
    local base
    base=$(grep -oE 'WOOTC_E2E_MIN_FREE_GIB:-[0-9]+' "$E2E" | grep -oE '[0-9]+$')
    [ -n "$base" ]
    [ "$base" -le 114 ]
}

@test "the requirement is overridable for unusual hosts" {
    grep -q 'WOOTC_E2E_MIN_FREE_GIB' "$E2E"
}

@test "the cached-ISO and reuse paths keep proportional headroom" {
    grep -q 'required_free_gib=75' "$E2E"
    grep -q 'required_free_gib=55' "$E2E"
}

@test "the keep count is overridable" {
    grep -q 'WOOTC_E2E_KEEP_RUNS:-3' "$E2E"
}

@test "the README timelapse only publishes green runs" {
    # run-e2e stamps .passed beside the recording ONLY on ALL TESTS PASSED;
    # publish-visual refuses any run lacking it (the hero must never show a
    # red run). --allow-red is the sole override.
    grep -q 'VIDEO_DIR/.passed' "$REPO_ROOT/tests/e2e/run-e2e.sh"
    grep -B5 'VIDEO_DIR/.passed' "$REPO_ROOT/tests/e2e/run-e2e.sh" | grep -q 'Green-only publish gate'
    local pv="$REPO_ROOT/tests/e2e/publish-visual.sh"
    grep -q 'name .passed' "$pv"
    grep -q 'not a GREEN run' "$pv"
    grep -q 'ALLOW_RED' "$pv"
}
