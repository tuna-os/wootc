#!/usr/bin/env bash
# tests/run.sh — the wootc test entry point, two tiers:
#
#   fast   bats unit suites (payload gates/transforms) + `go test` for the
#          cross-platform Go. No container, no VM, sub-second — this is the
#          red-green loop for TDD on new features and bug fixes.
#   slow   containerized integration (test-bridge.sh): the User Data Bridge,
#          browser/office/steam import, look mapping, WSL, go-native gates
#          proven end-to-end inside one privileged Fedora container. Needs
#          podman.
#
# Usage:
#   tests/run.sh            # fast tier (default)
#   tests/run.sh fast
#   tests/run.sh slow
#   tests/run.sh all
#
# Notes:
#   * /tmp is noexec on some dev hosts, which breaks `go test`; we point
#     GOTMPDIR at an exec-capable cache dir.
#   * Windows-tagged Go (app/*_windows.go) can't build/run on Linux by design,
#     so the Go tier covers the cross-platform packages only.

set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
TIER="${1:-fast}"

: "${GOTMPDIR:=$HOME/.cache/wootc-gotmp}"
mkdir -p "$GOTMPDIR"
export GOTMPDIR

rc=0

run_fast() {
    echo "══ fast tier ═════════════════════════════════════════════════════════"
    if command -v bats >/dev/null; then
        echo "── bats unit suites (tests/unit) ──"
        bats tests/unit/*.bats || rc=1
    else
        echo "!! bats not installed — skipping payload unit suites" >&2
    fi

    # Python unit tests are standalone scripts (no pytest dependency). They were
    # NOT wired in when tests/unit/test_qga_write.py landed, so the #42 guard
    # against short/zero-byte QGA writes never ran in CI — a test nothing
    # executes is not a test.
    if command -v python3 >/dev/null; then
        echo "── python unit tests (tests/unit/test_*.py) ──"
        for t in tests/unit/test_*.py; do
            [ -e "$t" ] || continue
            echo "   $t"
            python3 "$t" || rc=1
        done
    else
        echo "!! python3 not installed — skipping python unit tests" >&2
    fi

    # PowerShell static gate. The .ps1 payloads only ever execute inside a
    # Windows guest, minutes into an E2E run, so a syntax error there costs a
    # whole VM cycle to discover — which is exactly how two bugs shipped in
    # setup-wootc.ps1 (an invalid `$LASTEXITCODE:` scope reference, and a
    # `-notmatch` against un-stringified command output). Both are caught
    # statically in well under a second. See tests/lint-ps1.ps1.
    if command -v pwsh >/dev/null; then
        echo "── powershell lint (tests/lint-ps1.ps1) ──"
        pwsh -NoProfile -File tests/lint-ps1.ps1 || rc=1

        # PowerShell unit tests. The tests/field/*.ps1 verifiers grade release
        # and uninstall evidence on machines no runner has, so their pure
        # comparators are dot-sourced and driven from synthetic snapshots here.
        # A grader nothing exercises is a rubber stamp.
        echo "── powershell unit tests (tests/unit/test-*.ps1) ──"
        for t in tests/unit/test-*.ps1; do
            [ -e "$t" ] || continue
            echo "   $t"
            pwsh -NoProfile -File "$t" || rc=1
        done
    else
        echo "!! pwsh not installed — skipping PowerShell lint + unit tests" >&2
    fi

    if command -v go >/dev/null; then
        echo "── go test (fisherman TUI, cross-platform app) ──"
        # app/main.go has //go:embed all:frontend/dist, so the package will not
        # COMPILE without a built frontend. A dev box usually has one lying
        # around (which is why this tier passed locally while failing in CI);
        # a clean checkout does not. The Go tests here cover backend logic, not
        # the UI bundle, so stand up a placeholder rather than making the fast
        # tier depend on node. The real bundle is built by the release job.
        if [ ! -d app/frontend/dist ] || [ -z "$(ls -A app/frontend/dist 2>/dev/null)" ]; then
            mkdir -p app/frontend/dist
            printf '<!doctype html><title>placeholder</title>\n' > app/frontend/dist/index.html
            echo "   (created placeholder app/frontend/dist for the go:embed)"
        fi
        # app/: only the non-windows-tagged code compiles here (status mutex,
        # embedded catalog). fisherman TUI and core are fully cross-platform.
        ( cd app && go test ./... ) || rc=1
        ( cd fisherman/tui && go test ./... ) || rc=1
        ( cd fisherman/fisherman && go test ./... ) || rc=1
    else
        echo "!! go not installed — skipping Go tests" >&2
    fi
}

run_slow() {
    echo "══ slow tier (containerized integration) ═════════════════════════════"
    if command -v podman >/dev/null; then
        bash tests/migration/test-bridge.sh || rc=1
    else
        echo "!! podman not installed — skipping integration suite" >&2
    fi
}

case "$TIER" in
    fast) run_fast ;;
    slow) run_slow ;;
    all)  run_fast; run_slow ;;
    *) echo "usage: tests/run.sh [fast|slow|all]" >&2; exit 2 ;;
esac

echo
[ "$rc" -eq 0 ] && echo "✓ $TIER tier PASSED" || echo "✗ $TIER tier FAILED"
exit $rc
