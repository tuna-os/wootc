#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317,SC2329  # ENCODED_SCRIPT in heredoc, cleanup via trap
# run-e2e.sh — wootc end-to-end test orchestrator
#
# Prerequisites:
#   docker (or podman) with KVM access
#   pip install pywinrm
#   brew install websocat (optional, for VNC fallback)
#
# Usage:
#   ./run-e2e.sh                          # full e2e with default image
#   ./run-e2e.sh ghcr.io/tuna-os/bonito:gnome  # test specific image
#   ./run-e2e.sh --skip-build               # skip deployer rebuild
#   ./run-e2e.sh --keep                     # keep container after test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMAGE_REF="${1:-ghcr.io/tuna-os/yellowfin:gnome}"

# Parse flags
SKIP_BUILD=false
KEEP_CONTAINER=false
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
        --keep) KEEP_CONTAINER=true ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

cleanup() {
    if [ "$KEEP_CONTAINER" = false ]; then
        info "Cleaning up..."
        docker compose -f "$SCRIPT_DIR/compose.yml" down --volumes 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Step 0: Build deployer initramfs ─────────────────────────────────────────
if [ "$SKIP_BUILD" = false ]; then
    info "Building deployer initramfs..."
    cd "$REPO_ROOT/deployer"
    
    # Build the deployer container
    podman build -t wootc-deployer . || {
        fail "Deployer build failed"
        exit 1
    }
    
    # Extract kernel + initramfs
    mkdir -p out
    podman run --rm -v "$(pwd)/out:/out" wootc-deployer || {
        fail "Deployer extraction failed"
        exit 1
    }
    
    if [ ! -f out/vmlinuz ] || [ ! -f out/initramfs.img ]; then
        fail "Deployer output missing (out/vmlinuz, out/initramfs.img)"
        exit 1
    fi
    
    # Copy to test wootc-files directory
    mkdir -p "$SCRIPT_DIR/wootc-files"
    cp out/vmlinuz "$SCRIPT_DIR/wootc-files/"
    cp out/initramfs.img "$SCRIPT_DIR/wootc-files/"
    
    # Copy GRUB configs
    mkdir -p "$SCRIPT_DIR/wootc-files/grub"
    cp "$REPO_ROOT/grub/"*.cfg "$SCRIPT_DIR/wootc-files/grub/" 2>/dev/null || true
    
    pass "Deployer built: $(du -sh "$SCRIPT_DIR/wootc-files/vmlinuz" | cut -f1) kernel, $(du -sh "$SCRIPT_DIR/wootc-files/initramfs.img" | cut -f1) initramfs"
    cd "$SCRIPT_DIR"
fi

# ── Step 1: Check prerequisites ──────────────────────────────────────────────
info "Checking prerequisites..."

if [ ! -e /dev/kvm ]; then
    fail "/dev/kvm not available — KVM required for dockur/windows"
    exit 1
fi

if ! command -v docker &>/dev/null && ! command -v podman &>/dev/null; then
    fail "docker or podman required"
    exit 1
fi

DOCKER="docker"
if ! command -v docker &>/dev/null; then
    DOCKER="podman"
fi

# Check for pywinrm
python3 -c "import winrm" 2>/dev/null || {
    info "Installing pywinrm..."
    pip install pywinrm
}

pass "Prerequisites OK"

# ── Step 2: Start Windows VM ────────────────────────────────────────────────
info "Starting Windows VM (this will take 10-15 minutes for first boot)..."
info "Windows will auto-install via unattended answer file."

cd "$SCRIPT_DIR"

# Clean up any previous run
docker compose -f compose.yml down --volumes 2>/dev/null || true

# Create storage directory
mkdir -p storage wootc-files

# Start the container
$DOCKER compose -f compose.yml up -d windows

CONTAINER_NAME="wootc-e2e-windows"
STORAGE_DIR="$SCRIPT_DIR/storage"

# ── Step 3: Wait for Windows auto-install ────────────────────────────────────
info "Waiting for Windows auto-install to complete..."

# dockur/windows writes progress to the QEMU PTY
# We poll for installation completion markers
TIMEOUT=2400  # 40 minutes max
ELAPSED=0
QEMU_PTY=""

# Find the QEMU PTY path inside the container
while [ -z "$QEMU_PTY" ] && [ $ELAPSED -lt 120 ]; do
    QEMU_PTY=$($DOCKER exec "$CONTAINER_NAME" find /run -name "qemu.pty" 2>/dev/null | head -1) || true
    if [ -z "$QEMU_PTY" ]; then
        # Try storage directory
        QEMU_PTY=$(find "$STORAGE_DIR" -name "qemu.pty" 2>/dev/null | head -1) || true
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

info "QEMU PTY: ${QEMU_PTY:-not found yet, will poll storage dir}"

# Wait for Windows desktop (monitor RDP port or QEMU PTY)
info "Waiting for Windows to be ready (polling QEMU console + WinRM)..."

ELAPSED=0
WINDOWS_READY=false

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Check QEMU PTY for "Windows is ready" or similar
    if [ -f "$STORAGE_DIR/qemu.pty" ]; then
        if grep -q "Windows is ready\|desktop\|Welcome" "$STORAGE_DIR/qemu.pty" 2>/dev/null; then
            WINDOWS_READY=true
            break
        fi
    fi
    
    # Check if WinRM is responding
    if python3 -c "
import winrm
try:
    s = winrm.Session('127.0.0.1', auth=('wootc', 'wootc-test-123!'), transport='ntlm')
    r = s.run_ps('Write-Host ready')
    if r.status_code == 0:
        exit(0)
except:
    pass
exit(1)
" 2>/dev/null; then
        WINDOWS_READY=true
        break
    fi
    
    # Check RDP port
    if timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/3389" 2>/dev/null; then
        info "RDP port open — Windows may be ready"
        sleep 30  # Give Windows a moment to stabilize
        WINDOWS_READY=true
        break
    fi
    
    sleep 15
    ELAPSED=$((ELAPSED + 15))
    
    # Progress indicator every 2 minutes
    if [ $((ELAPSED % 120)) -eq 0 ]; then
        MINS=$((ELAPSED / 60))
        info "Still waiting... (~${MINS} minutes elapsed)"
    fi
done

if [ "$WINDOWS_READY" = false ]; then
    fail "Windows did not become ready within $TIMEOUT seconds"
    if [ -f "$STORAGE_DIR/qemu.pty" ]; then
        info "Last 20 lines of QEMU console:"
        tail -20 "$STORAGE_DIR/qemu.pty"
    fi
    exit 1
fi

pass "Windows is ready (took ~$((ELAPSED / 60)) minutes)"

# ── Step 4: Run wootc setup via WinRM ────────────────────────────────────────
info "Setting up wootc inside Windows via WinRM..."

# Wait for WinRM to be fully functional
sleep 10

# Copy setup script and files into Windows
# WinRM can't directly copy files in basic mode, so we use a workaround:
# Base64-encode the script and send it as a command

SETUP_SCRIPT=$(cat "$SCRIPT_DIR/setup-wootc.ps1")
ENCODED_SCRIPT=$(echo "$SETUP_SCRIPT" | base64 -w0)

python3 << PYEOF
import winrm
import time

s = winrm.Session(
    '127.0.0.1',
    auth=('wootc', 'wootc-test-123!'),
    transport='ntlm'
)

# Write the setup script to C:\wootc\
script_cmd = f'''
\$b64 = "{ENCODED_SCRIPT}"
\$script = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(\$b64))
Set-Content -Path "C:\\wootc\\setup-wootc.ps1" -Value \$script -Encoding UTF8
Write-Host "Script written"
'''
r = s.run_ps(script_cmd)
print("Write script:", r.status_code, r.std_out.decode()[:200])

# Run the setup script
r = s.run_ps('C:\\wootc\\setup-wootc.ps1 -ImageRef "{image}" -Hostname "wootc-test"'.format(image='$IMAGE_REF'))
print("Setup output:", r.std_out.decode())
if r.std_err:
    print("Setup stderr:", r.std_err.decode()[:500])

if r.status_code != 0:
    print("SETUP FAILED with status", r.status_code)
    exit(1)
PYEOF

if [ $? -ne 0 ]; then
    fail "wootc setup inside Windows failed"
    exit 1
fi

pass "wootc setup inside Windows completed"

# ── Step 5: Reboot Windows into wootc deployer ──────────────────────────────
info "Rebooting Windows into wootc deployer..."

# Trigger reboot via WinRM
python3 -c "
import winrm
s = winrm.Session('127.0.0.1', auth=('wootc', 'wootc-test-123!'), transport='ntlm')
s.run_ps('shutdown /r /t 5 /f')
print('Reboot triggered')
" 2>/dev/null || true

# Wait for Windows to go down
info "Waiting for Windows shutdown..."
sleep 15

# ── Step 6: Monitor deployer via QEMU serial console ────────────────────────
info "Monitoring deployer via QEMU serial console..."
info "This is the critical phase — watching for fisherman deployment..."

TIMEOUT=1200  # 20 minutes for deploy
ELAPSED=0
DEPLOY_COMPLETE=false
PTY="$STORAGE_DIR/qemu.pty"

# Wait for the PTY to show the new boot sequence
sleep 10

if [ ! -f "$PTY" ]; then
    fail "QEMU PTY not found at $PTY"
    exit 1
fi

# Tail the PTY and watch for key messages
LAST_LINE=$(wc -l < "$PTY" 2>/dev/null || echo 0)

while [ $ELAPSED -lt $TIMEOUT ]; do
    CURRENT_LINE=$(wc -l < "$PTY" 2>/dev/null || echo 0)
    
    if [ "$CURRENT_LINE" -gt "$LAST_LINE" ]; then
        # New output — check for key messages
        NEW_LINES=$(tail -n $((CURRENT_LINE - LAST_LINE)) "$PTY")
        
        if echo "$NEW_LINES" | grep -q "\[wootc\]"; then
            info "wootc: deployer started"
        fi
        
        if echo "$NEW_LINES" | grep -q "fisherman.*Partitioning"; then
            info "fisherman: partitioning disk"
        fi
        
        if echo "$NEW_LINES" | grep -q "Deploying image\|Pulling container image\|Installing OS"; then
            info "fisherman: deploying OS image"
        fi
        
        if echo "$NEW_LINES" | grep -q "Installation complete"; then
            DEPLOY_COMPLETE=true
            pass "fisherman: installation complete!"
            break
        fi
        
        if echo "$NEW_LINES" | grep -q "fatal\|panic\|kernel panic"; then
            fail "Deployer error detected:"
            echo "$NEW_LINES" | grep -E "fatal|panic|kernel panic"
            break
        fi
        
        LAST_LINE=$CURRENT_LINE
    fi
    
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    
    if [ $((ELAPSED % 60)) -eq 0 ]; then
        MINS=$((ELAPSED / 60))
        info "Still deploying... (~${MINS} minutes)"
    fi
done

if [ "$DEPLOY_COMPLETE" = false ]; then
    fail "Deployment did not complete within $TIMEOUT seconds"
    info "Last 30 lines of QEMU console:"
    tail -30 "$PTY"
    exit 1
fi

# ── Step 7: Wait for reboot and verify bootc system boots ───────────────────
info "Waiting for reboot into installed system..."
sleep 15

ELAPSED=0
TIMEOUT=300
BOOT_SUCCESS=false

while [ $ELAPSED -lt $TIMEOUT ]; do
    CURRENT_LINE=$(wc -l < "$PTY" 2>/dev/null || echo 0)
    
    if [ "$CURRENT_LINE" -gt "$LAST_LINE" ]; then
        NEW_LINES=$(tail -n $((CURRENT_LINE - LAST_LINE)) "$PTY")
        
        # Check for bootc/ostree boot messages
        if echo "$NEW_LINES" | grep -qE "ostree=|Starting version|Welcome to|login:"; then
            BOOT_SUCCESS=true
            pass "Bootc system booted successfully!"
            break
        fi
        
        if echo "$NEW_LINES" | grep -q "No bootable device\|BOOTMGR is missing\|kernel panic"; then
            fail "Boot failure detected"
            break
        fi
        
        LAST_LINE=$CURRENT_LINE
    fi
    
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ "$BOOT_SUCCESS" = false ]; then
    fail "Bootc system did not boot within $TIMEOUT seconds"
    info "Last 30 lines of QEMU console:"
    tail -30 "$PTY"
    exit 1
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   wootc E2E test: ALL TESTS PASSED   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""
info "Test summary:"
info "  Windows install:    OK"
info "  wootc setup:        OK"
info "  Deployer execution: OK"
info "  bootc system boot:  OK"
info "  Image tested:       $IMAGE_REF"
echo ""

exit 0
