#!/usr/bin/env bash
# setup-kvm-runner.sh — one-shot setup for a KVM-capable machine.
# Run this once on a fresh Ubuntu/Debian machine to prepare it
# for running the wootc e2e test.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/tuna-os/wootc/main/tests/e2e/setup-kvm-runner.sh | bash
#
# Or manually:
#   git clone --recurse-submodules https://github.com/tuna-os/wootc.git
#   cd wootc
#   bash tests/e2e/setup-kvm-runner.sh
#   ./tests/e2e/run-e2e.sh

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[setup]${NC} $*"; }
err()  { echo -e "${RED}[setup]${NC} $*"; exit 1; }

info "=== wootc KVM runner setup ==="

# ── Check KVM ─────────────────────────────────────────────────────────────
if [ ! -e /dev/kvm ]; then
    err "No /dev/kvm found. This machine does not support KVM."
fi
info "KVM available: $(ls -la /dev/kvm)"

# ── Install dependencies ───────────────────────────────────────────────────
info "Installing dependencies..."

if command -v apt-get &>/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        podman python3 python3-pip curl jq \
        shellcheck yamllint qemu-utils
elif command -v dnf &>/dev/null; then
    sudo dnf install -y \
        podman python3 python3-pip curl jq \
        ShellCheck yamllint qemu-img
else
    err "Unsupported package manager. Install podman, python3, jq manually."
fi

# ── Install pywinrm ────────────────────────────────────────────────────────
pip3 install pywinrm || sudo pip3 install pywinrm
python3 -c "import winrm; print('pywinrm OK')" || err "pywinrm install failed"

# ── Verify Docker/Podman ───────────────────────────────────────────────────
if command -v docker &>/dev/null; then
    DOCKER="docker"
elif command -v podman &>/dev/null; then
    DOCKER="podman"
else
    err "Neither docker nor podman found"
fi
info "Container runtime: $DOCKER"

# ── Check resources ────────────────────────────────────────────────────────
RAM=$(free -g | awk '/^Mem:/{print $2}')
DISK=$(df -h . | tail -1 | awk '{print $4}')
info "RAM: ${RAM}GB, Disk: ${DISK} free"

if [ "$RAM" -lt 8 ]; then
    err "Need at least 8GB RAM (have ${RAM}GB)"
fi

# ── Pull dockur/windows image ──────────────────────────────────────────────
info "Pulling dockur/windows image (this may take a few minutes)..."
$DOCKER pull dockurr/windows

# ── Build deployer ─────────────────────────────────────────────────────────
info "Building wootc deployer initramfs..."
if [ -f deployer/Containerfile ]; then
    podman build -f deployer/Containerfile -t wootc-deployer .
    mkdir -p deployer/out
    podman run --rm --entrypoint /bin/cat localhost/wootc-deployer /out/initramfs.img > deployer/out/initramfs.img
    podman run --rm --entrypoint /bin/cat localhost/wootc-deployer /out/vmlinuz > deployer/out/vmlinuz
    ls -lah deployer/out/vmlinuz deployer/out/initramfs.img
else
    # Running from tests/e2e/ — try relative path
    cd ../..
    podman build -f deployer/Containerfile -t wootc-deployer .
    mkdir -p deployer/out tests/e2e/wootc-files
    podman run --rm --entrypoint /bin/cat localhost/wootc-deployer /out/initramfs.img > deployer/out/initramfs.img
    podman run --rm --entrypoint /bin/cat localhost/wootc-deployer /out/vmlinuz > deployer/out/vmlinuz
    cp deployer/out/vmlinuz tests/e2e/wootc-files/
    cp deployer/out/initramfs.img tests/e2e/wootc-files/
    cp grub/*.cfg tests/e2e/wootc-files/grub/ 2>/dev/null || true
fi

info "Setup complete!"
info ""
info "To run the e2e test:"
info "  cd tests/e2e && ./run-e2e.sh"
info ""
info "This will:"
info "  1. Start Windows 11 VM (~10-15 min auto-install)"
info "  2. Wait for WinRM connectivity"
info "  3. Run wootc setup inside Windows"
info "  4. Reboot → deployer → fisherman → bootc install"
info "  5. Verify bootc system boots"
info ""
info "Total runtime: ~30-45 minutes"
