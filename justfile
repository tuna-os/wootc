# wootc Justfile
# Run `just --list` to see all targets.
# Prerequisites: podman, python3 + pywinrm, /dev/kvm

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false

# Export all variables as env vars (lets shebang recipes use $VAR syntax)
set export

# Default image to test
WOOTC_IMAGE := env_var_or_default("WOOTC_IMAGE", "ghcr.io/tuna-os/yellowfin:gnome")
E2E_DIR := justfile_directory() / "tests/e2e"
CTR := "wootc-e2e-windows"
WINRM_HOST := "127.0.0.1"
WINRM_USER := "wootc"
WINRM_PASS := "wootc-test-123!"

# ── Primary targets ───────────────────────────────────────────────────────────

# Full E2E: build deployer, install Windows, run wootc, verify boot
e2e image=WOOTC_IMAGE:
    cd "$E2E_DIR" && bash run-e2e.sh "{{ image }}"

# Quick E2E: skip Windows reinstall (reuse existing disk)
e2e-quick image=WOOTC_IMAGE:
    cd "$E2E_DIR" && bash run-e2e.sh --skip-install "{{ image }}"

# Build wootc deployer initramfs only
build-deployer:
    #!/usr/bin/env bash
    podman build -t wootc-deployer -f payload/deployer/Containerfile .
    mkdir -p "$E2E_DIR/wootc-files"
    podman run --rm -v "$E2E_DIR/wootc-files:/out" wootc-deployer
    echo "Deployer built:"
    ls -lh "$E2E_DIR/wootc-files/vmlinuz" "$E2E_DIR/wootc-files/initramfs.img"
    just fetch-grub-efi

# Copy grubx64.efi from the host into wootc-files/ (needed for BCD firmware entry)
# Searches common paths for grub2-efi-x64 / grub-efi-amd64 packages.
fetch-grub-efi:
    #!/usr/bin/env bash
    candidates=(
        /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi
        /boot/efi/EFI/fedora/grubx64.efi
        /boot/efi/EFI/almalinux/grubx64.efi
        /boot/efi/EFI/centos/grubx64.efi
        /usr/share/grub2/grubx64.efi
        /usr/lib64/efi/grub.efi
    )
    dest="$E2E_DIR/wootc-files/grubx64.efi"
    mkdir -p "$E2E_DIR/wootc-files"
    for f in "${candidates[@]}"; do
        if [ -f "$f" ]; then
            cp "$f" "$dest"
            echo "grubx64.efi: copied from $f ($(du -sh "$dest" | cut -f1))"
            exit 0
        fi
    done
    echo "WARNING: grubx64.efi not found on this host."
    echo "  Install grub2-efi-x64 (Fedora/RHEL) or grub-efi-amd64 (Debian/Ubuntu)"
    echo "  or manually place a grubx64.efi at: $dest"

# ── VM management ─────────────────────────────────────────────────────────────

# Start the Windows VM - does NOT wait for install (watch http://localhost:8006)
vm-start:
    #!/usr/bin/env bash
    cd "$E2E_DIR" && podman compose up -d windows
    echo "Windows VM starting. Watch: http://localhost:8006"
    sleep 5
    just fix-routing

# Stop and remove the Windows VM container
vm-stop:
    #!/usr/bin/env bash
    cd "$E2E_DIR" && podman compose down 2>/dev/null || true
    echo "VM stopped."

# Destroy VM container AND wipe the disk (requires a full Windows reinstall)
vm-nuke:
    #!/usr/bin/env bash
    cd "$E2E_DIR" && podman compose down --volumes 2>/dev/null || true
    rm -f "$E2E_DIR/storage/data.qcow2"
    echo "VM and disk nuked. Next start will reinstall Windows."

# ── Networking ────────────────────────────────────────────────────────────────

# Fix iptables DNAT so podman-mapped WinRM reaches the Windows VM
# dockur PREROUTING matches eth0 only; podman port-maps arrive on lo
fix-routing:
    #!/usr/bin/env bash
    VM_IP=$(podman exec "$CTR" bash -c \
        "ip route | awk '/172\\.30\\.[0-9]+\\.[0-9]+/{print \$NF; exit}'" 2>/dev/null \
        || echo "172.30.1.3")
    echo "VM IP: $VM_IP"
    for port in 5985 5986; do
        podman exec "$CTR" iptables -t nat -I PREROUTING \
            -i lo -p tcp --dport "$port" \
            -j DNAT --to-destination "${VM_IP}:${port}" 2>/dev/null \
            && echo "  DNAT lo:$port -> $VM_IP:$port added" \
            || echo "  lo:$port -> $VM_IP:$port already exists or skipped"
    done
    podman exec "$CTR" iptables -t nat -L PREROUTING -n -v

# ── WinRM interaction ─────────────────────────────────────────────────────────

# Probe WinRM - exit 0 if working, 1 if not
winrm-check:
    python3 "$E2E_DIR/winrm-check.py"

# Enable WinRM in a running Windows VM via QEMU monitor keystrokes
# Use when the VM was installed without WinRM (stale disk, old autounattend)
fix-winrm: fix-routing winrm-check
    #!/usr/bin/env bash
    podman exec "$CTR" mkdir -p /tmp
    podman cp "$E2E_DIR/fix-winrm.py" "$CTR:/tmp/fix-winrm.py"
    podman exec "$CTR" python3 /tmp/fix-winrm.py

# Run a one-shot PowerShell command via WinRM
winrm-run cmd="hostname":
    python3 "$E2E_DIR/winrm-run.py" '{{ cmd }}'

# ── Debugging ─────────────────────────────────────────────────────────────────

# Take a screenshot of the Windows VM (saves to /tmp/wootc-screen.png)
screenshot:
    #!/usr/bin/env bash
    podman cp "$E2E_DIR/screenshot.py" "$CTR:/tmp/screenshot.py"
    podman exec "$CTR" python3 /tmp/screenshot.py
    podman cp "$CTR:/tmp/wootc-screen.png" /tmp/wootc-screen.png
    echo "Screenshot saved: /tmp/wootc-screen.png"

# Stream the container logs
logs:
    podman logs "$CTR" --tail 50 -f

# Show iptables NAT rules inside the container
show-routing:
    podman exec "$CTR" iptables -t nat -L -n -v

# Open noVNC web console in browser
console:
    xdg-open http://localhost:8006 2>/dev/null || open http://localhost:8006 2>/dev/null || \
        echo "Open http://localhost:8006 in your browser"

# SSH into kanpur (the KVM host)
ssh-kanpur:
    ssh kanpur

# ── Code quality ──────────────────────────────────────────────────────────────

# Run shellcheck on all shell scripts
check:
    #!/usr/bin/env bash
    shellcheck "$E2E_DIR/run-e2e.sh"
    shellcheck "$E2E_DIR/setup-kvm-runner.sh"
    echo "shellcheck OK"

# Format shell scripts with shfmt
fmt:
    #!/usr/bin/env bash
    shfmt -w -i 4 "$E2E_DIR/run-e2e.sh" "$E2E_DIR/setup-kvm-runner.sh"
    echo "shfmt OK"
