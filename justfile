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
# Host-mapped RDP port for the local Windows VM (see tests/e2e/compose.yml).
RDP_PORT := env_var_or_default("WOOTC_E2E_RDP_PORT", "3389")

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

# Assemble a full offline release bundle: wootc.exe's runtime assets laid out
# exactly as they must land at C:\wootc\ on the target.
#
# Each piece is independently optional and degrades to fewer features rather
# than failing — QEMU alone gives "Boot in VM", plus the builder pair gives
# "Try in VM", plus an image gives an install that needs no network.
#
# QEMU is NOT vendored in this repo (~100 MB of third-party GPL binaries with
# their own DLL closure), so point qemu= at an extracted Windows QEMU install.
# Pass an empty image to skip staging the multi-GB image. Arguments are
# POSITIONAL (just does not take name=value here), so pass empties explicitly:
#   just release-bundle dist/wootc-offline /opt/qemu-w64 ghcr.io/tuna-os/yellowfin:gnome
#   just release-bundle dist/qemu-only     /opt/qemu-w64 ""
release-bundle out="dist/wootc-offline" qemu="" image=WOOTC_IMAGE:
    #!/usr/bin/env bash
    set -euo pipefail
    args=(--out "{{ out }}")
    [ -n "{{ qemu }}" ]  && args+=(--qemu "{{ qemu }}")
    [ -n "{{ image }}" ] && args+=(--image "{{ image }}")
    bash payload/bundle/make-release-bundle.sh "${args[@]}"

# Build the Try-in-VM builder artifacts (SPEC 6.1): the Alpine kernel +
# initramfs that turn an OCI image into a preview disk inside a headless VM.
#
# The Try-in-VM feature is fully implemented in app/vm_windows.go, but
# GetFreshVMCapability() refuses when these are absent — and nothing built
# them, so the button never appeared. They belong beside qemu-system-x86_64.exe
# under C:\wootc\qemu\ in a release bundle.
build-builder:
    bash payload/builder/build-builder.sh payload/builder/out
    ls -lh payload/builder/out/builder-vmlinuz payload/builder/out/builder-initramfs.img

# Pre-stage a bootc image so a migration needs no network (#177).
# Produces a portable containers-storage tree; deploy.sh passes it to fisherman
# as additionalImageStores and the multi-GB pull never happens. Ship the output
# beside wootc.exe; the installer stages it to C:\wootc\bundle\.
build-bundle image=WOOTC_IMAGE out="payload/bundle/out/bundle":
    bash payload/bundle/make-bundle.sh "{{ image }}" "{{ out }}"

# Regenerate the Windows app icon + resource object from app/build/appicon.svg.
# Only needed when the artwork changes: the resulting rsrc_windows_amd64.syso is
# COMMITTED, because we ship with plain `go build` (not `wails build`), and a
# plain go build embeds no resources unless a .syso is sitting in the package.
# The _windows_amd64 suffix is load-bearing — it keeps the object out of Linux
# builds, which the cross-platform test tier depends on.
# Needs: rsvg-convert (librsvg), python3-pillow, and akavel/rsrc.
build-icon:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v rsvg-convert >/dev/null || { echo "need rsvg-convert (librsvg)" >&2; exit 1; }
    command -v "$(go env GOPATH)/bin/rsrc" >/dev/null 2>&1 || go install github.com/akavel/rsrc@latest
    cd app/build
    rsvg-convert -w 256 -h 256 appicon.svg -o appicon.png
    mkdir -p windows
    python3 make-ico.py
    cd ..
    "$(go env GOPATH)/bin/rsrc" -ico build/windows/icon.ico \
        -manifest build/windows/wootc.manifest -arch amd64 \
        -o rsrc_windows_amd64.syso
    ls -lh build/windows/icon.ico rsrc_windows_amd64.syso

# Build the real wootc.exe (frontend + windows/amd64) into wootc-files/, where
# it's shared into the VM as \\host.lan\Data\wootc.exe (see compose.yml).
# native_webview2loader is required for the CDP endpoint (see tests/gui/run-cdp.sh).
build-wootc-exe:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{ FILES }}"
    (cd app/frontend && npm install --silent && npm run build >/dev/null)
    (cd app && GOOS=windows GOARCH=amd64 \
        go build -tags desktop,production,native_webview2loader -ldflags "-w -s" \
        -o "{{ FILES }}/wootc.exe" .)
    ls -lh "{{ FILES }}/wootc.exe"

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
        ./tests/e2e/run-e2e.sh --keep "$@"
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

# Start Windows VM locally. Self-heals two common rootless-laptop gotchas:
# a desktop's own Remote Desktop server squatting on the RDP port (picks the
# next free one instead), and a broken bridge/netavark path (falls back to
# `--network=pasta`, same escape hatch as WOOTC_E2E_NETWORK_MODE in
# compose.yml). The actual RDP port lands in storage/.rdp-port for `vm-wootc`.
vm-start:
    #!/usr/bin/env bash
    set -euo pipefail
    # compose.yml defaults to this image; build it once if missing (see
    # build-ssh-image.sh header) rather than failing on a bogus "localhost"
    # registry pull.
    if [ -z "${WOOTC_E2E_IMAGE:-}" ] && ! podman image exists localhost/wootc-e2e-windows-ssh:latest; then
        echo "localhost/wootc-e2e-windows-ssh:latest missing — building it once (tests/e2e/build-ssh-image.sh)..."
        bash "{{ E2E_DIR }}/build-ssh-image.sh"
    fi
    mkdir -p "{{ STORAGE }}"
    port="${WOOTC_E2E_RDP_PORT:-{{ RDP_PORT }}}"
    while ss -ltn 2>/dev/null | grep -q ":${port} "; do port=$((port + 1)); done
    [ "$port" = "${WOOTC_E2E_RDP_PORT:-{{ RDP_PORT }}}" ] || echo "Port {{ RDP_PORT }} taken (likely the host's own Remote Desktop) — using $port instead"
    export WOOTC_E2E_RDP_PORT="$port"
    echo "$port" > "{{ STORAGE }}/.rdp-port"
    cd "{{ E2E_DIR }}"
    if ! podman compose up -d windows 2>"{{ STORAGE }}/.vm-start.err"; then
        if grep -qi "tun interface\|netavark" "{{ STORAGE }}/.vm-start.err"; then
            echo "Bridge networking is broken on this host — retrying with --network=pasta..."
            podman compose down >/dev/null 2>&1 || true
            WOOTC_E2E_NETWORK_MODE=pasta podman compose up -d windows
        else
            cat "{{ STORAGE }}/.vm-start.err" >&2
            exit 1
        fi
    fi
    echo "RDP port: $port"
    echo "Watch: http://localhost:8006"

# Build wootc.exe + deployer/wubildr artifacts, boot the local Windows VM, and
# open an RDP session onto it — one command to reach an interactive desktop
# for manual migration testing. No run-e2e.sh driving it. Reuses whatever
# Windows disk/answer file is already staged in tests/e2e/storage (run `just
# e2e` once first if storage/ is empty). Once inside Windows, run
# \\host.lan\Data\wootc.exe by hand to click through the real GUI.
vm-wootc: build-wootc-exe build vm-start
    #!/usr/bin/env bash
    set -euo pipefail
    port=$(cat "{{ STORAGE }}/.rdp-port" 2>/dev/null || echo "{{ RDP_PORT }}")
    echo "Login:  wootc / wootc-test-123!"
    echo "Inside Windows: run \\\\host.lan\\Data\\wootc.exe to test the migration manually."
    echo "Opening RDP on localhost:$port once Windows finishes booting (retrying in the background)..."
    # setsid fully detaches this from the invoking shell's session, not just
    # its job table — plain `& disown` only survives the parent shell exiting
    # normally; it does not survive the parent's whole process group being
    # torn down (e.g. a CI step, or this recipe run from a script).
    setsid bash -c '
      set -euo pipefail
      # A bare TCP connect isn'"'"'t enough: the host-side port forward
      # (pasta or dockur'"'"'s NAT) accepts the handshake immediately and
      # only resets once it tries to reach the guest, so "port open" !=
      # "RDP ready". Retry the real handshake instead.
      ok=false
      for _ in $(seq 1 60); do
          xfreerdp "/v:localhost:'"$port"'" /u:wootc /p:"wootc-test-123!" \
              /cert:ignore +clipboard /dynamic-resolution 2>/dev/null && { ok=true; break; }
          sleep 10
      done
      # On some rootless hosts the bridge network is broken and the pasta
      # fallback'"'"'s double NAT hop (host -> container -> dockur'"'"'s own
      # DNAT -> guest) mishandles RDP'"'"'s data path even though the guest
      # is reachable. noVNC terminates in the container itself (no second
      # NAT hop) and stays reliable, so fall back to it rather than leaving
      # no interactive session at all.
      if [ "$ok" != true ]; then
          echo "RDP never came up cleanly on this host — falling back to noVNC: http://localhost:8006" >&2
          xdg-open http://localhost:8006 2>/dev/null || open http://localhost:8006 2>/dev/null || true
      fi
    ' </dev/null >/dev/null 2>&1 &
    disown

# Restore the Windows disk from its pristine snapshot, boot it, install
# wootc.exe onto the guest (C:\wootc\wootc.exe + a Public Desktop shortcut),
# launch it in the interactive session, and open noVNC — one command to reach
# a known-good manual-test run instead of accumulating state across boots
# (repeated dirty shutdowns of a locally-run VM can corrupt data.qcow2; this
# recipe sidesteps that by always starting from the snapshot). Slower than
# `vm-wootc` because of the full disk copy. Needs `just e2e` to have run at
# least once so storage/data.qcow2.pristine exists.
vm-wootc-fresh: build-wootc-exe build
    #!/usr/bin/env bash
    set -euo pipefail
    test -f "{{ STORAGE }}/data.qcow2.pristine" || {
        echo "No pristine snapshot at {{ STORAGE }}/data.qcow2.pristine — run 'just e2e' once first." >&2
        exit 1
    }
    just vm-stop
    echo "Restoring Windows disk from pristine snapshot..."
    rm -f "{{ STORAGE }}/data.qcow2"
    cp "{{ STORAGE }}/data.qcow2.pristine" "{{ STORAGE }}/data.qcow2"
    just vm-start
    echo "Waiting for the guest agent..."
    podman cp "{{ E2E_DIR }}/qga.py" "{{ CTR }}:/tmp/qga.py"
    for _ in $(seq 1 60); do
        podman exec "{{ CTR }}" python3 /tmp/qga.py ping >/dev/null 2>&1 && break
        sleep 10
    done
    podman exec "{{ CTR }}" python3 /tmp/qga.py ping >/dev/null 2>&1 || {
        echo "QGA never came up — the guest may still be booting; check 'just console'." >&2
        exit 1
    }
    # The real wootc.exe always fetches SHA256SUMS + boot artifacts from
    # GitHub Releases (installer_windows.go, fail-closed per #53) — it never
    # looks at files staged locally. WOOTC_DEPLOYER_MIRROR overrides the base
    # URL for exactly this kind of offline dev VM. Serve wootc-files/ over
    # HTTP from inside the container's own netns (same trick dockur uses for
    # noVNC on 8006: excluded from the QEMU_DNAT-to-guest catch-all so it
    # resolves locally instead of being redirected into the guest) — the
    # Samba share (\\host.lan\Data) already proves that path reaches the
    # guest, this just adds an HTTP listener beside it.
    echo "Regenerating SHA256SUMS and starting the local deployer mirror..."
    ( cd "{{ FILES }}" && sha256sum deployer-vmlinuz deployer-initramfs.img shimx64.efi grubx64.efi wubildr.efi > SHA256SUMS )
    mirror_port=18080
    podman exec "{{ CTR }}" iptables -t nat -C QEMU_DNAT -p tcp --dport "$mirror_port" -j RETURN 2>/dev/null || \
        podman exec "{{ CTR }}" iptables -t nat -I QEMU_DNAT 1 -p tcp --dport "$mirror_port" -j RETURN
    podman exec "{{ CTR }}" pkill -f "http.server $mirror_port" 2>/dev/null || true
    podman exec -d "{{ CTR }}" python3 -m http.server "$mirror_port" --directory /shared --bind 0.0.0.0
    echo "Installing wootc.exe + install artifacts + Desktop shortcut..."
    # A single script file pushed via `qga.py write` and run with a trivial
    # one-line -Command, rather than threading a multi-line PowerShell block
    # through bash quoting *and* the qga.py CLI argument *and* PowerShell's
    # own $-expansion — too many layers to keep straight reliably.
    # Fully-quoted heredoc: bash performs zero escaping/expansion inside, so
    # PowerShell's own $vars and UNC \\-paths need no backslash gymnastics.
    # The one dynamic value (the mirror port) goes in via a sed placeholder
    # afterward instead.
    cat > "{{ STORAGE }}/install-wootc.ps1" <<'PS1'
    New-Item -ItemType Directory -Force -Path C:\wootc\install | Out-Null
    Copy-Item \\host.lan\Data\wootc.exe C:\wootc\wootc.exe -Force
    foreach ($f in "deployer-vmlinuz","deployer-initramfs.img","shimx64.efi","grubx64.efi","wubildr.efi","SHA256SUMS") {
        if (Test-Path "\\host.lan\Data\$f") { Copy-Item "\\host.lan\Data\$f" "C:\wootc\install\$f" -Force }
    }
    @"
    set WOOTC_DEPLOYER_MIRROR=http://host.lan:__MIRROR_PORT__/
    start "" C:\wootc\wootc.exe
    "@ | Set-Content -Path C:\wootc\launch-manual.cmd -Encoding ascii
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut("C:\Users\Public\Desktop\wootc.lnk")
    $sc.TargetPath = "C:\wootc\launch-manual.cmd"
    $sc.WorkingDirectory = "C:\wootc"
    $sc.IconLocation = "C:\wootc\wootc.exe"
    $sc.Save()
    Write-Output "installed"
    PS1
    sed -i "s/__MIRROR_PORT__/$mirror_port/" "{{ STORAGE }}/install-wootc.ps1"
    podman cp "{{ STORAGE }}/install-wootc.ps1" "{{ CTR }}:/tmp/install-wootc.ps1"
    podman exec "{{ CTR }}" python3 /tmp/qga.py write /tmp/install-wootc.ps1 'C:\wootc-install.ps1'
    podman exec "{{ CTR }}" python3 /tmp/qga.py powershell "& 'C:\wootc-install.ps1'"
    echo "Launching wootc.exe in the interactive session..."
    # QGA runs as SYSTEM in session 0, which cannot render a WebView2 window
    # (see docs/gui-phase1-architecture.md / run-e2e.sh gui_install_arm) — an
    # interactive scheduled task in the autologged session is required.
    cat > "{{ STORAGE }}/launch-wootc.ps1" <<'PS1'
    Stop-Process -Name wootc -Force -ErrorAction SilentlyContinue
    schtasks /Delete /TN wootc-manual-launch /F 2>$null
    $start = (Get-Date).AddMinutes(1).ToString("HH:mm")
    $who = (Get-CimInstance Win32_ComputerSystem).UserName -replace "^.*\\",""
    if (-not $who) { $who = "wootc" }
    schtasks /Create /TN wootc-manual-launch /SC ONCE /ST $start /TR "C:\wootc\launch-manual.cmd" /RU $who /IT /RL HIGHEST /F | Out-Null
    schtasks /Run /TN wootc-manual-launch | Out-Null
    Write-Output ("launched as: " + $who)
    PS1
    podman cp "{{ STORAGE }}/launch-wootc.ps1" "{{ CTR }}:/tmp/launch-wootc.ps1"
    podman exec "{{ CTR }}" python3 /tmp/qga.py write /tmp/launch-wootc.ps1 'C:\wootc-launch.ps1'
    podman exec "{{ CTR }}" python3 /tmp/qga.py powershell "& 'C:\wootc-launch.ps1'"
    echo "Opening noVNC console..."
    xdg-open http://localhost:8006 2>/dev/null || open http://localhost:8006 2>/dev/null || \
        echo "Open http://localhost:8006 in your browser"

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

# Run shellcheck on the harness and the migration payloads.
# -S warning: info-level SC2016 fires falsely on single-quoted PowerShell
# payloads (the $vars are PowerShell's, not the shell's).
check:
    shellcheck -S warning "{{ E2E_DIR }}/run-e2e.sh" "{{ E2E_DIR }}/setup-kvm-runner.sh"
    shellcheck payload/migration/wootc-go-native payload/migration/wootc-wifi-bridge \
        payload/migration/wootc-wsl-bridge payload/migration/wootc-apply-look || true

# ── GUI E2E ───────────────────────────────────────────────────────────────────

# Mocked GUI conformance suite (Playwright, runs anywhere; no VM)
gui-test:
    cd tests/gui && npx playwright test gui.spec.js

# Rung-3 GUI E2E: drive the REAL wootc.exe over CDP inside a kept E2E VM
# (needs run-e2e.sh --keep state on the host; see tests/gui/run-cdp.sh)
gui-cdp host=KANPUR:
    tests/gui/run-cdp.sh --host {{ host }}

# Dogtail AT-SPI suite: drive the real GTK4 apps in a container (podman only).
# Guest-portable: run dogtail-suite.py inside a booted image to test the real
# deployment — exits 77 SKIP on images without dogtail (most; expected).
gui-dogtail:
    bash tests/gui/dogtail/run-dogtail.sh

# GUI-driven full E2E: Phase 1 armed by clicking through the REAL wootc.exe
# GUI over CDP (no preview mode), then deployer → Phase 2 → Phase 3 verified
# by the normal harness. Runs as instance g so it can share a host with the
# matrix. Needs wootc.exe rsynced into tests/e2e/wootc-files on the host.
remote-e2e-gui image=WOOTC_IMAGE:
    just _remote-launch keep --gui-install --phase3 --instance=g {{ image }}
