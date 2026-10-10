# Phase 1-first architecture — VM boot as primary, shared root.disk across phases

wootc has three phases of adoption (VM Boot → Native Boot → Standalone Linux), but they all boot the same `root.disk`. Phase 1 (QEMU) is the recommended first experience because it works immediately after install with no reboot and no NTFS dependency. To upgrade from Phase 1 to Phase 2, the user reboots and does not migrate. The OS is identical, and the User Data Bridge makes the same canonical mount layout in both modes.

**Status**: accepted

**Rejected alternative**: The SPEC originally positioned "Try in VM" as a preview and bare-metal dual-boot as the install path. That design needed a separate QEMU handoff in two stages (headless Alpine builder → interactive preview). It is now unnecessary. The Deployer already populates root.disk, and one command starts QEMU on the same disk.

## Implementation correction, 2026-09-26

[ADR 0004](0004-restore-vm-first-product.md) records the gap and the repair plan.
Today, the product needs a native deployment before it can use the installed VM path.
That does not satisfy this ADR. Phase 1 must work inside Windows first.
