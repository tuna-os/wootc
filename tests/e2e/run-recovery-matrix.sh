#!/usr/bin/env bash
# run-recovery-matrix.sh — Execute the Fault-Injection & Recovery matrix (#288).
#
# Exercises cancellation, interruption, and post-reboot failure across all 6
# boundaries:
#   1. image-pull
#   2. root-disk
#   3. efi-staging
#   4. bcd-arming
#   5. pre-reboot
#   6. deploy-failure
#
# For each cell:
#   - Injects fault at the boundary
#   - Verifies Windows boots normally without Automatic Repair
#   - Asserts no stale one-shot boot entry remains in BCD
#   - Retries install to verify idempotency (no duplicate BCD or EFI files)
#   - Verifies partial image blobs are reused and incomplete blobs discarded
#   - Uninstalls to verify restoration of Windows boot and power state
#   - Retains artifacts and evidence logs

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATRIX_TSV="$SCRIPT_DIR/matrix.tsv"
TIER="smoke"
BOUNDARY=""
IMAGE_OVERRIDE=""

for arg in "$@"; do
    case "$arg" in
        --tier=*)       TIER="${arg#--tier=}" ;;
        --boundary=*)   BOUNDARY="${arg#--boundary=}" ;;
        --image=*)      IMAGE_OVERRIDE="${arg#--image=}" ;;
        --help|-h)
            echo "Usage: $0 [--tier=smoke|full] [--boundary=<boundary>] [--image=<ref>]"
            exit 0
            ;;
    esac
done

echo "=== wootc Recovery & Fault-Injection Matrix (Tier: $TIER) ==="

TOTAL=0
PASSED=0
FAILED=0

while IFS=$'\t' read -r tier name image win_ver win_ed win_key opts; do
    # Skip comments and empty lines
    [[ "$tier" =~ ^[[:space:]]*# ]] && continue
    [ -z "$tier" ] && continue

    # Filter by tier (smoke is subset of full)
    if [ "$TIER" = "smoke" ] && [ "$tier" != "smoke" ]; then
        continue
    fi

    # Filter to recovery rows (having fault=)
    case "$opts" in
        *fault=*) ;;
        *) continue ;;
    esac

    fault_val=$(echo "$opts" | grep -o 'fault=[^,]*' | cut -d= -f2)
    if [ -n "$BOUNDARY" ] && [ "$BOUNDARY" != "$fault_val" ]; then
        continue
    fi

    [ -n "$IMAGE_OVERRIDE" ] && image="$IMAGE_OVERRIDE"

    TOTAL=$((TOTAL + 1))
    echo "── Running Recovery Cell: $name (fault: $fault_val, win: $win_ver $win_ed) ──"

    export WOOTC_E2E_WIN_VERSION="$win_ver"
    export WOOTC_E2E_WIN_EDITION="$win_ed"
    export WOOTC_E2E_WIN_KEY="$win_key"
    export WOOTC_E2E_FAULT_INJECT="$fault_val"

    if bash "$SCRIPT_DIR/run-e2e.sh" "$image" --fault-inject="$fault_val"; then
        echo "[PASS] $name"
        PASSED=$((PASSED + 1))
    else
        echo "[FAIL] $name"
        FAILED=$((FAILED + 1))
    fi
done < "$MATRIX_TSV"

echo "=========================================="
echo "Recovery Matrix Summary: $PASSED / $TOTAL passed ($FAILED failed)"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
