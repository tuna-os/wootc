#!/usr/bin/env bash
# ci-gate.sh — stable aggregate gate for main-branch protection.
#
# This script produces a single green/red verdict that answers: did every
# required CI job pass? The name "ci-gate" is stable; it does not drift as
# individual job names or matrix axes evolve. Branch-protection rules can
# require THIS check and only this check.
#
# Usage:
#   tests/ci-gate.sh check           exit 0 if all required jobs passed, else 1
#   tests/ci-gate.sh report          print a human-readable summary
#   tests/ci-gate.sh gate            check + report (default)
#
# Required jobs (keep in sync with .github/workflows/ci.yml + ci-tests.yml):
#   ci-tests / fast tier (bats + go)
#   ci-tests / migration integration (container)
#   ci-tests / lint (shellcheck + yamllint)
#   ci-tests / GUI screenshots render
#   CI / lint
#   CI / build-deployer
#   CI / build-app
#   CI / validate-recipe
#   CI / gui-tests
#
# When running outside GitHub Actions this script is advisory; it reads
# result markers from $CI_GATE_RESULTS_DIR (default: tests/ci-gate-results)
# and reports what it finds.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${CI_GATE_RESULTS_DIR:-$HERE/ci-gate-results}"
MODE="${1:-gate}"

# ── required gate definition ─────────────────────────────────────────────────
# Gates are stable names that must all be green. Adding a new gate requires a
# PR; removing one requires a PR. Optional / informational jobs (e.g. CDP
# Windows, e2e nightly) are NOT gates — they are documented below.
declare -A GATES=(
    ["fast-tier"]="Bats unit suites + Go cross-platform tests (tests/run.sh fast)"
    ["migration-integration"]="Containerized bridge suite (tests/migration/test-bridge.sh)"
    ["lint-scripts"]="ShellCheck + yamllint on payloads and harness scripts"
    ["gui-shots"]="GUI screenshot render + blank-detection"
    ["ci-lint"]="CI workflow lint (ShellCheck, yamllint, autounattend.xml)"
    ["build-deployer"]="Container build of deployer initramfs"
    ["build-app"]="Go + Node build of wootc.exe and Linux dashboard"
    ["validate-recipe"]="Fisherman recipe validation against default config"
    ["gui-tests"]="Playwright GUI walkthrough suite"
)

# ── NOT gates (run elsewhere or on-demand) ──────────────────────────────────
NOT_GATES=(
    "e2e-matrix:E2E matrix on hosted KVM runners (workflow_dispatch)"
    "e2e-kvm:E2E on self-hosted KVM (long-running, per-branch)"
    "e2e-nightly:Nightly E2E canary (scheduled)"
    "e2e-gui:GUI-driven E2E on laptop (manual trigger)"
    "e2e-snapshot:Snapshot regression gate (on-demand)"
    "pages:Docs site deploy (on push to main)"
)

# ── check individual gates from marker files ─────────────────────────────────
check_gates() {
    local failed=0 missing=0 gate
    for gate in "${!GATES[@]}"; do
        local marker="$RESULTS_DIR/${gate}.result"
        if [ -f "$marker" ]; then
            local status
            status=$(head -1 "$marker" | awk '{print $1}')
            if [ "$status" = "PASS" ]; then
                echo "  ✓ $gate"
            else
                echo "  ✗ $gate — $(cat "$marker" | head -1)"
                failed=$((failed + 1))
            fi
        else
            echo "  ? $gate — no result file (missing job or result collection)"
            missing=$((missing + 1))
        fi
    done

    echo
    if [ $failed -gt 0 ] || [ $missing -gt 0 ]; then
        echo "GATE: FAIL ($failed failed, $missing missing of ${#GATES[@]} required)"
        return 1
    fi
    echo "GATE: PASS (${#GATES[@]}/${#GATES[@]} required)"
    return 0
}

# ── record a single result (called from CI jobs) ─────────────────────────────
record() {
    local gate="$1" status="${2:-PASS}" msg="${3:-}"
    mkdir -p "$RESULTS_DIR"
    printf '%s %s %s\n' "$status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" > "$RESULTS_DIR/${gate}.result"
    echo "ci-gate: recorded $gate → $status"
}

report() {
    echo "══ ci-gate ══════════════════════════════════════════════════════════"
    echo "Required gates for main-branch protection:"
    echo
    for gate in "${!GATES[@]}"; do
        printf '  %-28s  %s\n' "$gate" "${GATES[$gate]}"
    done
    echo
    echo "NOT gates (run on demand / schedule):"
    for entry in "${NOT_GATES[@]}"; do
        printf '  %-28s  %s\n' "${entry%%:*}" "${entry#*:}"
    done
    echo
    check_gates
}

case "$MODE" in
    check)  check_gates ;;
    report) report ;;
    gate)   report ;;
    record) record "${2:-}" "${3:-PASS}" "${4:-}" ;;
    *)
        echo "usage: ci-gate.sh [check|report|gate|record <name> <PASS|FAIL> [msg]]" >&2
        exit 2
        ;;
esac
