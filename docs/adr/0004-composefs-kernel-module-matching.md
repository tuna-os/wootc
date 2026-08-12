# ADR 0004: ComposeFS Kernel & Module Matching Strategy (#78)

## Status
Approved Technical Specification

## Context
When booting a composefs deployment during Phase 2 under Secure Boot, GRUB boots the deployers signed kernel (/boot/vmlinuz-deployer) with the targets UKI initrd. Because the UKI embedded vmlinuz lacks a detached PE signature (only the .efi wrapper is signed), shim/GRUB cannot verify it under Secure Boot.

Consequently, the running system executes a kernel version that does not match the sealed image /usr/lib/modules/<version> tree, causing post-boot kernel module loading (e.g. Wi-Fi drivers, GPU drivers, zram) to fail.

---

## 1. Architectural Strategy: Target Signed Kernel / UKI Direct Chainloading (Option 2/1)

To ensure strict parity between the running kernel and the sealed /usr/lib/modules tree across all target images, wootc adopts the following dual-path kernel resolution architecture:

1. **Option 2 (Standalone Signed Target Kernel)**:
   - Target bootc images publish a standalone, signed kernel binary (/usr/lib/modules/<version>/vmlinuz) in addition to the UKI.
   - During Phase-1/Phase-2 staging, wootc extracts the target image signed vmlinuz and matching initrd, staging them directly onto the EFI System Partition (ESP).
   - GRUB chainloads the target own signed kernel, matching the image module tree exactly.

2. **Option 1 (Signed UKI Chainloading with kargs Addons)**:
   - For images shipping UKIs exclusively, GRUB direct chainloads the signed UKI (chainloader /EFI/Linux/<target-uki>.efi).
   - Command line arguments (root=UUID=..., wootc.host_uuid=...) are passed via systemd-stub signed kargs addons or MOK-enrolled ephemeral signatures.

---

## 2. Requirements & Verification

- **Module Tree Alignment**: uname -r in the booted target system MUST match /usr/lib/modules/$(uname -r).
- **Zero Missing Module Timeouts**: Eliminates dev-zram0 and driver load timeouts during systemd initialization.
- **E2E Validation**: The E2E test matrix validates module loading (lsmod, modprobe zram) in Phase-2 composefs boots.
