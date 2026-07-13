# wootc End-to-End Tests

Automated testing using [dockur/windows](https://github.com/dockur/windows) — Windows
running inside a Docker container via QEMU. Tests verify the full wootc
pipeline: Windows setup → GRUB chainload → deployer → bootc system boot.

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
│  │  2. WinRM enabled (port 5985)                 │    │
│  │  3. RDP enabled (port 3389)                   │    │
│  │  4. Test script connects via WinRM            │    │
│  │  5. setup-wootc.ps1: creates root.disk,       │    │
│  │     installs GRUB, copies deployer files       │    │
│  │  6. Reboot → GRUB2 → deployer initramfs       │    │
│  │  7. Deployer pulls image, runs fisherman       │    │
│  │  8. Reboot → installed bootc system            │    │
│  │                                               │    │
│  │  QEMU serial console: $STORAGE/qemu.pty       │    │
│  │  QEMU monitor: $STORAGE/qemu.monitor          │    │
│  │  VNC: port 5900                                │    │
│  │  WinRM: port 5985 (inside container)           │    │
│  └──────────────────────────────────────────────┘    │
│                                                       │
│  Shared volumes:                                       │
│    ./wootc-files:/wootc  — deployer + GRUB injected    │
│    ./storage:/storage   — VM disk + QEMU artifacts     │
└──────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# Build the deployer initramfs first
cd ../../deployer
podman build -t wootc-deployer .
podman run --rm -v $(pwd)/out:/out wootc-deployer

# Copy deployer output to test directory
cp out/vmlinuz out/initramfs.img ../tests/e2e/wootc-files/

# Run the e2e test
cd ../tests/e2e
./run-e2e.sh
```

## Prerequisites

- Linux host with KVM support (`/dev/kvm` accessible)
- Docker or Podman
- At least 8 GB RAM available
- At least 80 GB free disk space
- `pywinrm` Python package (`pip install pywinrm`)
- `websocat` for VNC automation (`brew install websocat`)

## Test Steps (automated by run-e2e.sh)

1. Start dockur/windows container
2. Wait for Windows auto-install (monitor qemu.pty for "Windows is ready")
3. Wait for RDP port 3389 to accept connections
4. Connect via WinRM
5. Run setup-wootc.ps1 inside Windows:
   - Create C:\wootc\disks\root.disk (2GB sparse, enough for test)
   - Copy deployer kernel + initramfs from shared volume
   - Install GRUB2 to ESP, add BCD entry
   - Configure Windows to boot wootc once
6. Reboot the VM
7. Monitor qemu.pty for deployer progress:
   - "[wootc] Searching for /wootc/disks/root.disk..."
   - "fisherman: Partitioning disk"
   - "Deploying image"
   - "Installation complete!"
8. Verify the installed system boots (login prompt on serial)
9. (Optional) Connect via SSH to verify bootc status
