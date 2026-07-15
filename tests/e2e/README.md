# wootc End-to-End Tests

Automated testing using [dockur/windows](https://github.com/dockur/windows) — Windows
running inside a Docker container via QEMU. Tests verify the full wootc
pipeline: Windows setup → one-shot wubildr chainload → deployer → bootc
system boot.

The Windows 11 VM uses UEFI Secure Boot and a TPM 2.0 emulator. The harness
verifies those features and KVM acceleration from QEMU's command line before
it waits for installation.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│ docker compose up -d                                  │
│                                                       │
│  dockur/windows container                             │
│  ┌──────────────────────────────────────────────┐    │
│  │ QEMU VM (Windows 11)                          │    │
│  │                                               │    │
│  │  1. Windows boots (auto-install via answer)   │    │
│  │  2. Dockur copies ./oem to C:\\OEM             │    │
│  │  3. SYSTEM task installs QEMU Guest Agent       │    │
│  │  4. QGA runs setup and exposes logs             │    │
│  │  5. Setup creates root.disk and BCD entry       │    │
│  │  6. Reboot → wubildr → deployer initramfs       │    │
│  │  7. Deployer pulls image, runs fisherman        │    │
│  │  8. Reboot → installed Phase 2 Linux            │    │
│  │                                               │    │
│  │  QEMU serial console: $STORAGE/qemu.pty       │    │
│  │  QEMU monitor: $STORAGE/qemu.monitor          │    │
│  │  VNC: port 5900                                │    │
│  │  QGA: /run/shm/qga.sock (private virtio channel)│   │
│  └──────────────────────────────────────────────┘    │
│                                                       │
│  Shared volumes:                                       │
│    ./oem:/oem:ro         — local setup + boot payload  │
│    ./storage:/storage    — VM disk + QEMU artifacts    │
└──────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# On any Linux machine with KVM:
curl -sSL https://raw.githubusercontent.com/tuna-os/wootc/main/tests/e2e/setup-kvm-runner.sh | bash
cd tests/e2e && ./run-e2e.sh

# Or test a specific image:
./run-e2e.sh ghcr.io/tuna-os/bonito:gnome
```

To avoid re-downloading the multi-gigabyte installer, keep a pristine Windows
ISO at `tests/e2e/iso-cache/windows-11.iso`. The runner makes a separate,
copy-on-write working copy at `storage/custom.iso`, so Dockur cannot alter the
cache. A different cache location can be selected with:

```bash
WOOTC_WINDOWS_ISO=/srv/iso/windows-11.iso ./run-e2e.sh --skip-build
```

## Manual Setup

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/tuna-os/wootc.git
cd wootc

# Install prerequisites
# The QGA client uses only Python's standard library.

# Build the deployer initramfs
podman build -f payload/deployer/Containerfile -t wootc-deployer .
mkdir -p payload/deployer/out tests/e2e/wootc-files/grub
podman run --rm --entrypoint /bin/cat localhost/wootc-deployer \
    /out/deployer-initramfs.img > payload/deployer/out/deployer-initramfs.img
podman run --rm --entrypoint /bin/cat localhost/wootc-deployer \
    /out/deployer-vmlinuz > payload/deployer/out/deployer-vmlinuz
cp payload/deployer/out/deployer-vmlinuz tests/e2e/wootc-files/
cp payload/deployer/out/deployer-initramfs.img tests/e2e/wootc-files/
cp /path/to/wubildr.efi tests/e2e/wootc-files/
cp platform/grub/*.cfg tests/e2e/wootc-files/grub/
cp platform/grub/*.cfg tests/e2e/wootc-files/grub/

# Run the e2e test (~30-45 minutes)
cd tests/e2e && ./run-e2e.sh
```

## Prerequisites

- Linux host with KVM support (`/dev/kvm` accessible)
- Docker or Podman
- At least 8 GB RAM available
- At least 80 GB free disk space
- `tests/e2e/wootc-files/wubildr.efi`: the custom GRUB core image with its
  embedded NTFS bootstrap configuration. A stock `grubx64.efi` cannot replace it.

## Test Steps (automated by run-e2e.sh)

1. Stage the local OEM payload and start dockur/windows.
2. Wait for the unattended Windows install. During `specialize`, the answer
   file creates a one-shot SYSTEM task; at the first automatic desktop logon it
   installs the cached QEMU Guest Agent MSI and starts the agent service.
3. The runner waits for QGA and uses its private virtio-serial channel to run
   PowerShell as SYSTEM, retrieve `C:\OEM` logs, and invoke `setup-wootc.ps1`.
   No guest networking, SMB, WinRM, or Windows password is needed.
4. `setup-wootc.ps1` runs from that OEM payload and:
   - Create C:\wootc\disks\root.disk (2GB sparse, enough for test)
   - Copy deployer kernel, initramfs, and wubildr.efi from C:\OEM
   - Install wubildr to the ESP and add a one-shot BCD entry
   - Configure Windows to boot wootc once
4. Monitor qemu.pty for deployer progress:
   - "[wootc] Searching for /wootc/disks/root.disk..."
   - "fisherman: Partitioning disk"
   - "Deploying image"
   - "Installation complete!"
6. Re-arm the one-shot BCD entry through QGA and verify the installed Phase 2
   Linux system boots, then verify the entry returns to Windows through QGA.

See the repository-root [HANDOFF.md](../../HANDOFF.md) for the QGA migration
design, package cache details, and troubleshooting evidence.
