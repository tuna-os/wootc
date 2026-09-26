# ADR 0004: Restore Linux inside Windows as Phase 1

Status: accepted product direction, reaffirmed by the maintainer on 2026-09-26.
Implementation remains incomplete. This ADR supersedes the VM deferral in #318.
It clarifies [ADR 0001](0001-phase1-first-architecture.md), not a new optional feature.

## The intended journey

1. **Phase 1: Linux inside Windows.** Prepare and run the chosen distro in a VM.
   Let the person explore their apps and data without a host reboot into Linux.
2. **Phase 2: native boot.** Offer direct Linux boot when the person is ready.
   Preserve the same installed system, accounts, settings, and user work.
3. **Phase 3: independent Linux.** Move off the Windows host volume only after
   separate data checks, consent, and recovery preparation.

The first VM is the person's installed system, not a disposable demo.
Do not reset it, deploy another image, or lose its changes at native promotion.
Migration begins during Phase 1 and continues through the same plan and ledger.

“No reboot into Linux” does not promise that Windows never needs a restart.
Some PCs need a Windows feature or firmware change before hardware virtualization works.
Explain that prerequisite separately, before any install work.
If the PC cannot support the VM, show why and offer a separately chosen native path.
Do not silently replace the intended first experience with a deployer reboot.

## How the product diverged

| Evidence | What it establishes |
|---|---|
| #178, `CONTEXT.md`, ADR 0001 | VM first, then native boot of the same disk |
| #318 / commit `50941d1` | Fresh builder deferred to reduce the distribution footprint; post-install VM treated as sufficient |
| `app/app.go` install pipeline | Current main path stages native boot and needs the offline deployer |
| `app/vm_windows.go` | Launcher exists, but uses `format=vhdx` for raw `root.disk`; fixed resource allocation and generic name |
| Fresh builder path | Separate temporary `preview.raw`; no durable shared-install lifecycle; success checks only file size after process exit |
| `payload/builder/wootc-builder-init` | Writes `STATUS=SUCCESS`, while the host parser does not require that terminal marker |
| `InstallPreviewForReal` | Renames/copies a preview and arms boot without a proven VM stop or shared-disk compatibility gate |
| `tests/e2e/phase1/assert-phase1.ps1` | Checks a staged native install and old `root.vhdx`; does not prove Linux runs inside Windows |
| WinUI phase-C plan | Previously omitted the VM surface because it inherited the deferral |

A renamed test or a visible button cannot fix these gaps.
Do not claim Phase 1 support until the actual Windows-hosted guest passes its gate.

## Architecture to build

Use the same provisioner contract in two execution environments:

| Environment | Role | Host disk access |
|---|---|---|
| Helper VM inside Windows | Prepare the persistent Linux disk while Windows remains available | Only dedicated image files and approved exports |
| Native deployer | Repair or perform an explicitly chosen native transition when required | Controlled offline access under existing safety gates |

The preferred path creates the persistent raw `root.disk` at its final location.
A helper VM receives it as a virtual block device, plus a separate scratch disk.
Pass the selected image by immutable digest and authenticated install inputs.
Reuse the proven bootc/fisherman work through a backend-neutral target interface.
Keep boot-entry, host ESP, and BitLocker changes out of VM preparation.

Do not pass the mounted Windows system partition into the helper VM.
Windows owns NTFS while it runs. File shares or scoped export bundles carry user data.
A VM writes its own image through Windows file APIs; it does not mount host NTFS.
Place large OCI and scratch data on disk, with per-volume free-space checks.
The old 2 GB RAM-backed builder is not a capacity plan for desktop images.

After provision completes, shut down the helper cleanly and verify its result.
Launch the installed system in the interactive VM from the same raw image.
Its firmware, virtual ESP, kernel, and root layout need an explicit tested contract.
Do not assume any existing native image can boot from firmware without that proof.

Keep target identity and user-data paths stable between VM and native modes.
The guest detects its mode and selects the appropriate bridge backend.
A native-only NTFS attach hook must not hang a VM boot that has a direct block device.
The VM must not require host ESP files that its virtual firmware cannot see.

## Disk ownership and VM lifecycle

The engine owns a durable VM/install lifecycle, not a detached QEMU process.
Allow one writer to each image. Check locks across engine instances and restarts.
Do not permit native promotion, uninstall, resize, or replacement while a VM owns the disk.

Proposed states:

```text
absent → preparing_vm → vm_ready → vm_running → vm_stopped
                 ↘ failed              ↘ needs_recovery
vm_stopped → native_preflight → native_ready → native_verified
```

Each state transition needs observable evidence and a run identity.
A QEMU process exit is not successful provisioning.
Require a bounded, authenticated result with image digest, disk identity,
filesystem/boot verification, account outcome, and explicit terminal status.
Then prove the installed guest actually boots and the expected session is usable.

A process start is not a ready desktop.
Track guest identity, OS identity, session readiness, and guest shutdown separately.
Keep persistent firmware variables per VM and verify their compatibility at upgrades.
Use collision-free channels and ports; do not expose guest services on every host interface.
Passwords and transport secrets never go into command arguments or console logs.

A host shutdown requests clean guest shutdown and waits within a tested limit.
After forced termination, mark recovery required and check the filesystem before reuse.
Cancellation cannot delete a disk that contains the person's later work.

## Data and migration in Phase 1

Present the same logical Documents, Pictures, and other selected folders in both modes.
Resolve actual Windows Known Folders, including redirected/cloud-backed folders.
Use a tested Windows-host share backend with explicit access scopes and identity.
Do not assume that every Windows QEMU package supports virtiofs or 9p exports.
Start read-only unless the person chooses a write-through share with clear semantics.
A write through a shared folder changes the Windows original and needs an honest label.

VM-local files, installed apps, and preferences live in the shared persistent image.
Copies imported there survive native promotion.
Do not rerun completed imports merely because the boot mode changes.
Credential collection stays in the original Windows user's session with explicit consent.
Follow the [migration extension plan](../specs/migration-extensions.md) for item-level results.

## Native promotion is a separate transaction

Stop the VM and confirm release of its image handles.
Check the hardware, BitLocker plan, Secure Boot trust, kernel drivers, disk health,
space, and boot artifacts before any firmware change.
Capture the current boot configuration and prepare a Windows recovery route.

Export the exact installed kernel/initramfs and signed chain required for native boot.
Verify that native and VM initramfs paths both work after promotion and future upgrades.
Stage the host ESP only at this point; arm a one-shot native boot after user confirmation.
Never reprovision the root image as part of this transition.

A successful native first boot writes verifiable evidence tied to the same disk/install ID.
Windows reads it after return. Failure preserves the VM path where the image is healthy.
Automatic rollback touches boot configuration it owns, not unrelated firmware entries.
Phase 3 remains separate and cannot use “VM ready” as evidence of data independence.

## Distribution and older PCs

Ship or fetch a pinned, verified VM runtime and firmware set as supported artifacts.
Do not depend on an arbitrary `qemu-system-x86_64.exe` found on PATH for elevated execution.
Retain license notices, digests, source provenance, and a supported upgrade policy.
An offline bundle includes all required assets and the selected image closure.

Probe actual accelerator operation, CPU features, RAM, disk, and display capability.
A Windows feature flag alone does not prove that QEMU can use the accelerator.
Allocate guest resources from the host budget; do not reserve 4 GB and 4 CPUs unconditionally.
Do not silently select a slow software emulator and promise a comfortable desktop.
Offer plain-language remediation or an explicit native alternative where needed.
Measure performance on older physical PCs as well as nested test hosts.

## Delivery order and proof

| Slice | Deliverable | Required proof |
|---|---|---|
| 1 | Correct current disk-format and readiness checks; honest capability reports | Invalid/empty disk and failed builder never become ready; raw launch arguments; no stale success |
| 2 | Shared persistent-image provisioner backend in helper VM | Fresh image prepared without host ESP/BCD/Fast Startup changes; explicit result; source Windows stays usable |
| 3 | Managed interactive VM, verified runtime, resource budget, private channels | Usable Linux session on Windows; clean stop/restart; disk locking; crash recovery |
| 4 | Canonical data bridge and migration preview/results | Selected Windows files accessible; private profiles isolated; imported and guest-created data survive restart |
| 5 | Transactional native promotion of the same image | VM changes survive native boot and Windows return; VM boot still works afterwards |
| 6 | WinUI parity and distro release integration | Native UI drives VM-first flow; brand assets and outcomes match; offline clean-machine proof |

Corral/KubeVirt can host the Windows fixture if nested acceleration works.
If it cannot, use a capable Windows host for the guest-VM gate.
A Linux VM directly hosted by KubeVirt is not evidence of Linux inside Windows.
The existing native E2E matrix remains useful, but does not prove Phase 1.

The acceptance scenario begins on a fresh Windows desktop with a selected distro.
It ends with a usable Linux desktop in a window, without a host Linux boot.
Create a file and change an app preference, restart the VM, then promote natively.
Verify the same file and preference, return to Windows, and launch the VM again.
Record host boot identity, boot configuration, disk identity, guest evidence, and screenshots.
