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
# Default remote E2E host. himachal is the healthiest runner (952 GiB, linger
# enabled); kanpur/dilli are known-bad (docs/agent-lessons.md §11). Override
# with WOOTC_E2E_HOST=<host>.
KANPUR := env_var_or_default("WOOTC_E2E_HOST", "himachal")

# ── Tests ─────────────────────────────────────────────────────────────────────

# Fast red-green loop: bats unit suites + cross-platform go test. No container.
test:
    bash tests/run.sh fast

# Alias for the fast tier.
test-fast: test

# Containerized integration (User Data Bridge, WSL, go-native gates). Needs podman.
test-slow:
    bash tests/run.sh slow

# Everything: fast + slow.
test-all:
    bash tests/run.sh all

# Refresh the README/Pages walkthrough from a recorded run (host or local dir).
publish-visual src="--from-host himachal":
    bash tests/e2e/publish-visual.sh {{ src }}

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

# ── Remote E2E ────────────────────────────────────────────────────────────────
#
# All launch recipes follow docs/agent-lessons.md §7:
#   * systemd-run --user (never nohup) with XDG_RUNTIME_DIR/HOME set, so
#     rootless podman resolves user storage and the run survives ssh disconnect
#     (linger must be enabled once: `loginctl enable-linger james`).
#   * refuse to launch over a live run instead of silently killing it.
#   * never `rm -rf storage/*` — it destroys the pristine Windows snapshot and
#     the 7 GiB ISO cache. A fresh install only needs data.qcow2 removed.
# Logs land in /tmp/wootc-e2e-<short-sha>.log on the host.

# Shared launcher. wipe="fresh" forces a full Windows reinstall.
_remote-launch wipe *flags:
    #!/usr/bin/env bash
    set -euo pipefail
    ssh {{ KANPUR }} WIPE={{ wipe }} 'bash -s' -- {{ flags }} <<'REMOTE'
    set -euo pipefail
    cd ~/wootc
    cur=tests/e2e/storage/run-e2e.current
    if [ -f "$cur" ] && ! grep -q "stage=exited" "$cur"; then
        age=$(( $(date +%s) - $(stat -c %Y "$cur") ))
        if [ "$age" -lt 300 ]; then
            echo "REFUSING: live run (run-e2e.current updated ${age}s ago). Stop it first: systemctl --user stop wootc-e2e" >&2
            exit 1
        fi
    fi
    git pull --ff-only && git submodule update --init --recursive
    systemctl --user stop wootc-e2e 2>/dev/null || true
    systemctl --user reset-failed wootc-e2e 2>/dev/null || true
    podman stop wootc-e2e-windows 2>/dev/null || true
    podman rm wootc-e2e-windows 2>/dev/null || true
    if [ "${WIPE:-}" = fresh ]; then rm -f tests/e2e/storage/data.qcow2; fi
    LOG=/tmp/wootc-e2e-$(git rev-parse --short HEAD).log
    systemd-run --user --unit=wootc-e2e --collect \
        --setenv=XDG_RUNTIME_DIR=/run/user/$(id -u) \
        --setenv=HOME=$HOME \
        -p StandardOutput=append:$LOG \
        -p StandardError=append:$LOG \
        -p WorkingDirectory=$HOME/wootc \
        ./tests/e2e/run-e2e.sh --skip-build --keep "$@"
    echo "unit=wootc-e2e log=$LOG"
    REMOTE

# Fresh full E2E (Windows reinstall + deploy, ~60-90 min)
remote-e2e image=WOOTC_IMAGE:
    just _remote-launch fresh {{ image }}

# Quick E2E: restore pristine Windows, re-arm, deploy (~20-40 min)
remote-e2e-quick image=WOOTC_IMAGE:
    just _remote-launch keep --skip-install {{ image }}

# Full three-phase rung: quick E2E + graduate to a blank native disk (--phase3)
remote-e2e-phase3 image=WOOTC_IMAGE:
    just _remote-launch keep --skip-install --phase3 {{ image }}

# Pull latest code on Kanpur
remote-pull:
    ssh {{ KANPUR }} 'cd ~/wootc && git pull'

# Push local commits, then hard-reset the E2E host's checkout to match origin
# exactly (including submodules). Local edits made directly on the host via
# ssh are easy to lose track of and silently diverge from what's committed —
# this recipe is the guard against that: it always leaves the host on
# exactly what's in git, never a hand-patched mix.
remote-sync:
    #!/usr/bin/env bash
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "Local working tree has uncommitted changes — commit or stash before syncing." >&2
        exit 1
    fi
    git push origin HEAD
    ssh {{ KANPUR }} '
        set -euo pipefail
        cd ~/wootc
        git fetch origin
        git checkout main
        git reset --hard origin/main
        git submodule sync --recursive
        git submodule update --init --recursive
    '

# Fix permissions
remote-chown:
    ssh {{ KANPUR }} 'sudo chown -R james:james ~/wootc/tests/e2e/'

# Kill stale processes
remote-cleanup:
    ssh {{ KANPUR }} \
        'kill $(pgrep rootlessport 2>/dev/null); \
         sudo kill $(pgrep qemu-system swtpm 2>/dev/null)'

# Stop container
remote-stop:
    ssh {{ KANPUR }} 'podman stop {{ CTR }} 2>/dev/null; podman rm {{ CTR }} 2>/dev/null'

# Restore disk from snapshot
remote-restore name="snap":
    ssh {{ KANPUR }} 'cp ~/wootc/tests/e2e/storage/data.qcow2.{{ name }} \
        ~/wootc/tests/e2e/storage/data.qcow2'

# Create deployer.qcow2 (obsolete with 256MB ESP, kept for reference)
remote-deployer-disk:
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

# Tail runner log (default: the newest /tmp/wootc-e2e-*.log on the host)
remote-logs suffix="":
    ssh {{ KANPUR }} 'f={{ if suffix == "" { "$(ls -t /tmp/wootc-e2e-*.log | head -1)" } else { "/tmp/wootc-e2e-" + suffix + ".log" } }}; echo "== $f =="; tail -f "$f"'

# Check runner progress (default: newest log)
remote-status suffix="":
    ssh {{ KANPUR }} 'f={{ if suffix == "" { "$(ls -t /tmp/wootc-e2e-*.log | head -1)" } else { "/tmp/wootc-e2e-" + suffix + ".log" } }}; echo "== $f =="; grep -aE "PASS|FAIL|QGA.*avail|STEP|OEM|deploy" "$f" | tail -10'

# Watch serial console for deployer boot
remote-serial:
    ssh {{ KANPUR }} \
        'podman logs {{ CTR }} 2>&1 | strings | grep -i \
        "linux\|initrd\|Booting\|kernel\|fisherman\|hd1\|scsi\|insmod\|error\|panic" | tail -25'

# Check container
remote-container:
    ssh {{ KANPUR }} \
        'podman ps --format "{{"{{"}}.Names}} {{"{{"}}.Status}}" | grep {{ CTR }}'

# Check QEMU process
remote-qemu:
    ssh {{ KANPUR }} \
        'podman exec {{ CTR }} ps -ef 2>/dev/null | grep "[q]emu" | head -1 | \
        awk "{print \$2, \$8}" || echo "QEMU not running"'

# Show disk sizes
remote-disks:
    ssh {{ KANPUR }} 'ls -lh ~/wootc/tests/e2e/storage/*.qcow2 2>/dev/null'

# Check root.disk and deployer files
remote-check-files:
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

# Run shellcheck on the harness and the migration payloads
check:
    shellcheck "{{ E2E_DIR }}/run-e2e.sh" "{{ E2E_DIR }}/setup-kvm-runner.sh"
    shellcheck payload/migration/wootc-go-native payload/migration/wootc-wifi-bridge \
        payload/migration/wootc-wsl-bridge payload/migration/wootc-apply-look || true
