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
        # embedded catalog). fisherman TUI is fully cross-platform.
        ( cd app && go test ./... ) || rc=1
        ( cd fisherman/tui && go test ./... ) || rc=1
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
