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
│  │  3. C:\\OEM\\install.bat runs setup-wootc.ps1  │    │
│  │  4. Setup creates root.disk and BCD entry      │    │
│  │  5. Reboot → wubildr → deployer initramfs      │    │
│  │  6. Deployer pulls image, runs fisherman       │    │
│  │  7. Reboot → installed Phase 2 Linux           │    │
│  │                                               │    │
│  │  QEMU serial console: $STORAGE/qemu.pty       │    │
│  │  QEMU monitor: $STORAGE/qemu.monitor          │    │
│  │  VNC: port 5900                                │    │
│  │  WinRM: port 5985 (inside container)           │    │
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
pip install pywinrm    # WinRM client for automation

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
- `pywinrm` Python package (`pip install pywinrm`)
- `websocat` for VNC automation (`brew install websocat`)
- `tests/e2e/wootc-files/wubildr.efi`: the custom GRUB core image with its
  embedded NTFS bootstrap configuration. A stock `grubx64.efi` cannot replace it.

## Test Steps (automated by run-e2e.sh)

1. Stage the local OEM payload and start dockur/windows.
2. Wait for the unattended Windows install. At the first automatic desktop
   logon, the E2E answer file executes `C:\OEM\install.bat`; no guest
   networking, SMB, or WinRM is needed for this initial handoff.
3. `setup-wootc.ps1` runs from that OEM payload and:
   - Create C:\wootc\disks\root.disk (2GB sparse, enough for test)
   - Copy deployer kernel, initramfs, and wubildr.efi from C:\OEM
   - Install wubildr to the ESP and add a one-shot BCD entry
   - Configure Windows to boot wootc once
4. Monitor qemu.pty for deployer progress:
   - "[wootc] Searching for /wootc/disks/root.disk..."
   - "fisherman: Partitioning disk"
   - "Deploying image"
   - "Installation complete!"
5. Re-arm the one-shot BCD entry and verify the installed Phase 2 Linux system
   boots, then verify the entry returns to Windows.

WinRM is still used by the Phase 2 re-arm assertion today. It is deliberately
not a dependency of the Windows installation or initial wootc handoff; a QEMU
Guest Agent control path is the planned replacement for that remaining step.
