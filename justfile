# wootc Justfile — QGA-based E2E workflow
# Run `just --list` to see all targets.
# Prerequisites: podman, qemu-img, /dev/kvm, Python 3

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false
set export

# ── Configuration ─────────────────────────────────────────────────────────────
WOOTC_IMAGE := env_var_or_default("WOOTC_IMAGE", "ghcr.io/tuna-os/yellowfin:gnome")
E2E_DIR := justfile_directory() / "tests/e2e"
STORAGE := E2E_DIR / "storage"
FILES := E2E_DIR / "wootc-files"
CTR := "wootc-e2e-windows"
KANPUR := "kanpur"

# ── Local E2E ─────────────────────────────────────────────────────────────────

# Full E2E: build deployer, install Windows, run wootc, verify boot
e2e image=WOOTC_IMAGE:
    cd "{{ E2E_DIR }}" && bash run-e2e.sh "{{ image }}"

# Quick E2E: skip Windows reinstall (reuse existing disk)
e2e-quick image=WOOTC_IMAGE:
    cd "{{ E2E_DIR }}" && bash run-e2e.sh --skip-install "{{ image }}"

# Build all artifacts
build:
    just build-deployer
    just build-wubildr
    just bundle-systemd-boot

# Bundle Fedora's reproducible unsigned systemd-boot build beside wootc.exe.
# Secure-Boot machines reject this path unless CI substitutes a trusted
# Authenticode-valid systemd-bootx64.efi.signed artifact.
bundle-systemd-boot:
    #!/usr/bin/env bash
    mkdir -p app/build/bin/efi
    podman run --rm --entrypoint /bin/cat localhost/wootc-deployer \
        /out/systemd-bootx64.efi > app/build/bin/efi/systemd-bootx64.efi
    test -s app/build/bin/efi/systemd-bootx64.efi

# Build deployer initramfs
build-deployer:
    #!/usr/bin/env bash
    podman build -t wootc-deployer -f payload/deployer/Containerfile .
    mkdir -p "{{ FILES }}"
    podman run --rm -v "{{ FILES }}:/out" wootc-deployer
    ls -lh "{{ FILES }}/deployer-vmlinuz" "{{ FILES }}/deployer-initramfs.img"

# Build custom GRUB (wubildr.efi)
build-wubildr:
    #!/usr/bin/env bash
    podman build -t wootc-wubildr -f payload/wubildr/Containerfile .
    mkdir -p "{{ FILES }}"
    podman run --rm --entrypoint /bin/cat wootc-wubildr /out/wubildr.efi > "{{ FILES }}/wubildr.efi"
    ls -lh "{{ FILES }}/wubildr.efi"

# ── Kanpur E2E ────────────────────────────────────────────────────────────────

# Fresh full E2E on Kanpur (~30 min)
kanpur-e2e:
    ssh {{ KANPUR }} 'cd ~/wootc && git pull && \
        sudo chown -R james:james tests/e2e/ && \
        kill $(pgrep rootlessport 2>/dev/null) && \
        sudo kill $(pgrep qemu-system swtpm 2>/dev/null) && \
        podman stop {{ CTR }} 2>/dev/null; podman rm {{ CTR }} 2>/dev/null && \
        podman compose -f tests/e2e/compose.yml down 2>/dev/null && \
        cd tests/e2e && rm -rf storage/* 2>/dev/null && \
        PATH="$HOME/.local/bin:$PATH" nohup bash run-e2e.sh --skip-build --keep \
        > /tmp/wootc-e2e-qgaN.log 2>&1 & echo "PID=$!"'

# Quick E2E on Kanpur (skip install + build)
kanpur-e2e-quick:
    ssh {{ KANPUR }} 'cd ~/wootc && git pull && \
        sudo chown -R james:james tests/e2e/ && \
        sudo kill $(pgrep qemu-system swtpm 2>/dev/null) && \
        podman stop {{ CTR }} 2>/dev/null; podman rm {{ CTR }} 2>/dev/null && \
        podman compose -f tests/e2e/compose.yml down 2>/dev/null && \
        cd tests/e2e && \
        PATH="$HOME/.local/bin:$PATH" nohup bash run-e2e.sh --skip-build --skip-install --keep \
        > /tmp/wootc-e2e-qgaN.log 2>&1 & echo "PID=$!"'

# Pull latest code on Kanpur
kanpur-pull:
    ssh {{ KANPUR }} 'cd ~/wootc && git pull'

# Fix permissions
kanpur-chown:
    ssh {{ KANPUR }} 'sudo chown -R james:james ~/wootc/tests/e2e/'

# Kill stale processes
kanpur-cleanup:
    ssh {{ KANPUR }} \
        'kill $(pgrep rootlessport 2>/dev/null); \
         sudo kill $(pgrep qemu-system swtpm 2>/dev/null)'

# Stop container
kanpur-stop:
    ssh {{ KANPUR }} 'podman stop {{ CTR }} 2>/dev/null; podman rm {{ CTR }} 2>/dev/null'

# Restore disk from snapshot
kanpur-restore name="snap":
    ssh {{ KANPUR }} 'cp ~/wootc/tests/e2e/storage/data.qcow2.{{ name }} \
        ~/wootc/tests/e2e/storage/data.qcow2'

# Create deployer.qcow2 (obsolete with 256MB ESP, kept for reference)
kanpur-deployer-disk:
    ssh {{ KANPUR }} \
        'qemu-img create -f qcow2 ~/wootc/tests/e2e/storage/deployer.qcow2 256M'

# ── QGA ───────────────────────────────────────────────────────────────────────

# Check QGA
qga-ping:
    ssh {{ KANPUR }} \
        'podman exec {{ CTR }} python3 /tmp/qga.py ping 2>&1 && echo ALIVE || echo DEAD'

# Run PowerShell via QGA
qga-ps cmd="hostname":
    ssh {{ KANPUR }} \
        'podman exec {{ CTR }} python3 /tmp/qga.py powershell "{{ cmd }}"'

# Read file from Windows VM
qga-read path="C:/OEM/wootc-e2e.log":
    ssh {{ KANPUR }} \
        'podman exec {{ CTR }} python3 /tmp/qga.py read "{{ path }}" 2>/dev/null'

# Read OEM log
qga-oem-log:
    ssh {{ KANPUR }} \
        'podman exec {{ CTR }} python3 /tmp/qga.py read "C:\\OEM\\wootc-e2e.log" 2>/dev/null | strings'

# QGA guest info
qga-info:
    ssh {{ KANPUR }} \
        'podman exec {{ CTR }} python3 /tmp/qga.py info'

# Reboot Windows VM
qga-reboot:
    ssh {{ KANPUR }} \
        'podman exec {{ CTR }} python3 /tmp/qga.py powershell "shutdown /r /t 0 /f"'

# ── Deployment ────────────────────────────────────────────────────────────────

# Extract signed shim + GRUB + modules from Fedora container
extract-signed-efi:
    #!/usr/bin/env bash
    ssh {{ KANPUR }} '
        CID=$(podman run -d quay.io/fedora/fedora:44 \
            bash -c "dnf install -y -q shim-x64 grub2-efi-x64 grub2-efi-x64-modules 2>/dev/null && \
            cp /boot/efi/EFI/fedora/{shimx64,grubx64,mmx64}.efi /tmp/ && \
            for m in ntfs loopback ntfscomp ext2 scsi; do \
                cp /usr/lib/grub/x86_64-efi/\${m}.mod /tmp/ 2>/dev/null; \
            done && echo DONE")
        podman wait $CID >/dev/null 2>&1
        for f in shimx64.efi grubx64.efi mmx64.efi ntfs.mod loopback.mod ntfscomp.mod ext2.mod scsi.mod; do
            podman cp $CID:/tmp/${f} ~/wootc/tests/e2e/wootc-files/ 2>/dev/null || true
        done
        podman rm $CID >/dev/null 2>&1
        ls -lh ~/wootc/tests/e2e/wootc-files/{shimx64,grubx64,scsi,ntfs,loopback}*
    '

# Populate ESP with shim + GRUB + deployer files (via QGA)
deploy-esp:
    ssh {{ KANPUR }} 'podman exec {{ CTR }} python3 /tmp/qga.py powershell \
        "\$s = \"\\\\\\\\host.lan\\\\Data\"; \
         \$e = \"E:\\\\EFI\\\\wootc\\\\\"; \
         New-Item -ItemType Directory -Force -Path \$e | Out-Null; \
         foreach (\$f in @(\"shimx64.efi\",\"grubx64.efi\",\"scsi.mod\",\"ntfs.mod\",\"loopback.mod\")) { \
             Copy-Item \"\$s\\\$f\" \"\$e\\\$f\" -Force; \
         }; \
         Copy-Item \"C:\\wootc\\install\\deployer-vmlinuz\" \"\${e}deployer-vmlinuz\" -Force; \
         Copy-Item \"C:\\wootc\\install\\deployer-initramfs.img\" \"\${e}deployer-initramfs.img\" -Force; \
         \$cfg = @(); \
         \$cfg += \"set root=(hd0,gpt1)\"; \
         \$cfg += '\''echo Booting wootc deployer from ESP...'\''; \
         \$cfg += \"linux /EFI/wootc/deployer-vmlinuz quiet\"; \
         \$cfg += \"initrd /EFI/wootc/deployer-initramfs.img\"; \
         \$cfg += \"boot\"; \
         \$cfg -join \"\`r\`n\" | Set-Content \"\${e}grub.cfg\" -Encoding ASCII; \
         Write-Host \"ESP populated\""'

# Set BCD one-shot to shimx64.efi
bcd-shim:
    ssh {{ KANPUR }} 'podman exec {{ CTR }} python3 /tmp/qga.py powershell \
        "\$bcd = (& bcdedit /copy \"{bootmgr}\" /d \"wootc Deployer\" 2>&1) | Out-String; \
         \$match = [regex]::Match(\$bcd, \"{([0-9a-fA-F-]+)}\"); \
         if (\$match.Success) { \
             \$guid = \$match.Groups[0].Value; \
             & bcdedit /set \$guid path \"\\EFI\\wootc\\shimx64.efi\"; \
             & bcdedit /set \"{fwbootmgr}\" bootsequence \$guid /addfirst; \
             Write-Host \"BCD one-shot: \$guid\"; \
         }"'

# Full deploy + reboot
deploy-all: deploy-esp bcd-shim qga-reboot

# Snapshot data.qcow2
snapshot:
    ssh {{ KANPUR }} \
        'cp ~/wootc/tests/e2e/storage/data.qcow2 ~/wootc/tests/e2e/storage/data.qcow2.snap'

# ── Monitoring ────────────────────────────────────────────────────────────────

# Tail runner log
kanpur-logs suffix="qga33":
    ssh {{ KANPUR }} 'tail -f /tmp/wootc-e2e-{{ suffix }}.log'

# Check runner progress
kanpur-status suffix="qga33":
    ssh {{ KANPUR }} \
        'grep -E "PASS|FAIL|QGA.*avail|STEP|OEM|deploy" /tmp/wootc-e2e-{{ suffix }}.log | tail -10'

# Watch serial console for deployer boot
kanpur-serial:
    ssh {{ KANPUR }} \
        'podman logs {{ CTR }} 2>&1 | strings | grep -i \
        "linux\|initrd\|Booting\|kernel\|fisherman\|hd1\|scsi\|insmod\|error\|panic" | tail -25'

# Check container
kanpur-container:
    ssh {{ KANPUR }} \
        'podman ps --format "{{"{{"}}.Names}} {{"{{"}}.Status}}" | grep {{ CTR }}'

# Check QEMU process
kanpur-qemu:
    ssh {{ KANPUR }} \
        'podman exec {{ CTR }} ps -ef 2>/dev/null | grep "[q]emu" | head -1 | \
        awk "{print \$2, \$8}" || echo "QEMU not running"'

# Show disk sizes
kanpur-disks:
    ssh {{ KANPUR }} 'ls -lh ~/wootc/tests/e2e/storage/*.qcow2 2>/dev/null'

# Check root.disk and deployer files
kanpur-check-files:
    ssh {{ KANPUR }} \
        'podman exec {{ CTR }} python3 /tmp/qga.py powershell \
        "Test-Path C:\\wootc\\disks\\root.disk; \
         Get-ChildItem C:\\wootc\\install | Select Name,Length"'

# ── Local VM management ───────────────────────────────────────────────────────

# Start Windows VM locally
vm-start:
    cd "{{ E2E_DIR }}" && podman compose up -d windows
    echo "Watch: http://localhost:8006"

# Stop Windows VM
vm-stop:
    cd "{{ E2E_DIR }}" && podman compose down 2>/dev/null || true

# Destroy VM and disk
vm-nuke:
    cd "{{ E2E_DIR }}" && podman compose down --volumes 2>/dev/null || true
    rm -f "{{ STORAGE }}/data.qcow2"

# Open noVNC web console
console:
    xdg-open http://localhost:8006 2>/dev/null || \
        open http://localhost:8006 2>/dev/null || \
        echo "Open http://localhost:8006 in your browser"

# ── Debugging ─────────────────────────────────────────────────────────────────

# Take a screenshot
screenshot:
    #!/usr/bin/env bash
    podman cp "{{ E2E_DIR }}/screenshot.py" "{{ CTR }}:/tmp/screenshot.py"
    podman exec "{{ CTR }}" python3 /tmp/screenshot.py
    podman cp "{{ CTR }}:/tmp/wootc-screen.png" /tmp/wootc-screen.png
    echo "Saved: /tmp/wootc-screen.png"

# Stream container logs
logs:
    podman logs "{{ CTR }}" --tail 50 -f

# SSH into Kanpur
ssh:
    ssh {{ KANPUR }}

# Run shellcheck
check:
    shellcheck "{{ E2E_DIR }}/run-e2e.sh" "{{ E2E_DIR }}/setup-kvm-runner.sh"
