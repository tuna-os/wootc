#!/usr/bin/env bash
# run-phase1.sh — Phase-1 E2E: exercise the real wootc.exe (headless mode)
# against an already-booted E2E Windows VM and assert the resulting state.
# See README.md in this directory. Runs in ~2 minutes; no deployer boot.
#
# Prerequisites: a running wootc-e2e-windows container (run-e2e.sh --keep)
# with QGA responsive, and node+go on this host for the build.

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
E2E_DIR=$(dirname "$SCRIPT_DIR")
APP_DIR="$E2E_DIR/../../app"
FILES_DIR="$E2E_DIR/wootc-files"
CONTAINER="${WOOTC_E2E_CONTAINER:-wootc-e2e-windows}"
IMAGE_REF="${WOOTC_IMAGE:-ghcr.io/tuna-os/yellowfin:gnome}"
SKIP_BUILD=false
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
    esac
done

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
step() { echo -e "${CYAN}[STEP]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

qga() {
    podman exec "$CONTAINER" python3 /qga.py --socket /run/shm/qga.sock powershell "$1"
}

# ── 1. Build the real product ────────────────────────────────────────────────
if [ "$SKIP_BUILD" = false ]; then
    step "Building wootc.exe (frontend + windows/amd64)..."
    (cd "$APP_DIR/frontend" && npm install --silent && npm run build >/dev/null)
    (cd "$APP_DIR" && GOOS=windows GOARCH=amd64 \
        go build -tags desktop,production -ldflags "-w -s" -o "$FILES_DIR/wootc.exe" .)
fi
[ -f "$FILES_DIR/wootc.exe" ] || fail "wootc.exe not found in $FILES_DIR"

# ── 2. Stage the assert script (Windows PowerShell needs CRLF + BOM) ────────
step "Staging assert script..."
printf '\xEF\xBB\xBF' > "$FILES_DIR/assert-phase1.ps1"
sed 's/$/\r/' "$SCRIPT_DIR/assert-phase1.ps1" >> "$FILES_DIR/assert-phase1.ps1"

# ── 3. QGA reachable? ────────────────────────────────────────────────────────
step "Probing QGA..."
qga "echo qga-ok" | grep -q qga-ok || fail "QGA not responsive in $CONTAINER"

# ── 4. Copy product + pre-stage deployer artifacts into the guest ──────────
# downloadDeployer skips files that already exist, so pre-staging makes the
# download step a no-op (no network dependency in the test).
step "Copying wootc.exe and pre-staging deployer artifacts..."
qga 'New-Item -ItemType Directory -Force -Path C:\wootc\install | Out-Null; Copy-Item \\host.lan\Data\wootc.exe C:\wootc\wootc.exe -Force; foreach ($f in "deployer-vmlinuz","deployer-initramfs.img","shimx64.efi","grubx64.efi","wubildr.efi") { if (Test-Path "\\host.lan\Data\$f") { Copy-Item "\\host.lan\Data\$f" "C:\wootc\install\$f" -Force } }'

# ── 5. Run the headless install ──────────────────────────────────────────────
step "Running wootc.exe install (headless)..."
INSTALL_OUT=$(qga "C:\wootc\wootc.exe install -image $IMAGE_REF -username testuser -password testpass -hostname wootc-test 2>&1")
echo "$INSTALL_OUT"
echo "$INSTALL_OUT" | grep -q "install complete" || fail "headless install did not complete"
pass "headless install completed"

# ── 6. Assert the resulting system state ────────────────────────────────────
step "Running Windows-side assertions..."
ASSERT_OUT=$(qga 'powershell -ExecutionPolicy Bypass -File \\host.lan\Data\assert-phase1.ps1 2>&1')
echo "$ASSERT_OUT"
echo "$ASSERT_OUT" | grep -q "PHASE1-RESULT: PASS" || fail "assertions failed"

pass "Phase-1 E2E passed"
