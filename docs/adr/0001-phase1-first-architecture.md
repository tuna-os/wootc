# Phase 1-first architecture — VM boot as primary, shared root.disk across phases

wootc has three phases of adoption (VM Boot → Native Boot → Standalone Linux), but they all boot the same `root.disk`. Phase 1 (QEMU) is the recommended first experience because it works immediately after install with no reboot and no NTFS dependency. The user upgrades from Phase 1 to Phase 2 by rebooting — not migrating — because the OS is identical and the User Data Bridge produces the same canonical mount layout in both modes.

**Status**: accepted

**Rejected alternative**: The SPEC originally positioned "Try in VM" as a preview and bare-metal dual-boot as the install path. That required a separate two-stage QEMU handoff (headless Alpine builder → interactive preview) that is now unnecessary — the Deployer already populates root.disk, and launching QEMU against the same disk is a single command.

## Implementation correction, 2026-09-26

[ADR 0004](0004-restore-vm-first-product.md) records the gap and the repair plan.
The current product requires native deployment before the installed VM path.
That does not satisfy this ADR. Phase 1 must work inside Windows first.
