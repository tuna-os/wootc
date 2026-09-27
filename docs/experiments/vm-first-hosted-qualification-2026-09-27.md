# Fresh hosted VM-first qualification plan — 2026-09-27

This is a source and resource plan for #178. No VM was started for this review.
The preserved `phase1-whpx` guest, its disk, TPM and CPU configuration remain unchanged.
Its disconnected QGA cannot establish Windows identity or a usable desktop.
The current BitLocker acceptance is a separate native-install gate.

## Source to qualify

Build one isolated candidate from main `09f2698` and integrate the reviewed source stacks:

| Source | Exact reviewed head | Purpose |
|---|---|---|
| #418 | `e85f9d6fa9cb03fe61623e76485349c878e8d47f` | Managed persistent raw disk, firmware variables, signed runtime and process ownership |
| #419 | `4fb714534c21aea0a1241e9c4efc05d0b243c242` | Verified Windows QEMU runtime packaging and extraction |
| #422 | `5168dd5f9ea6ee96f64f235fdefd7b13913827a9` | Image/runtime-bound storage profile selection |

These branches overlap. Inspect ancestry and merge each missing change once; do not
assemble independent launchers or replace managed `PrepareVM`/`BootInVM` with a
harness QEMU command. Reconcile the current native shell and engine DTO source,
then test their real RPC connection. The old `tests/e2e/phase1` workflow stages a
native installation; it cannot qualify this journey.

`/tmp/wootc-capacity-trial` remains an unstaged experiment. Preserve its three edits.
Its proposed profile binds the exact derived Yellowfin image
`ttl.sh/2e6295b0-50ea-42b2-838a-57df8a1022be@sha256:4562f4f0fde8cc0ba49e7ce627be2ba35d803c9aa768e79220a1a58c3b0d148b`
to runtime manifest `48cbafea9f469e195108f9fcb304101a69423cc8193f87fbd540ac813214c8c3`.
A bounded registry HEAD during this review returned HTTP 200 and that exact digest.
TTL availability is temporary: recheck before building; refuse expiration or changed
bytes. Do not silently replace it with a mutable tag. The added matching GNOME RPM
and its retained provenance must accompany this experimental image.

The 32/8 GiB Linux experiment established helper installation and manual desktop
persistence. Its file was created through a shell. It did not establish Windows-hosted
GNOME editor save/close/reopen, or a shipping capacity floor. The release profile
registry and build-time experiment selector remain empty unless explicitly approved.

## Fresh host prerequisites

Use a new workflow and owned storage, not the preserved fixture. First run a small
read-only qualification stage; only a passing stage may begin fresh Windows Setup.
GitHub documents standard public Linux runners as 4 CPUs, 16 GB RAM and 14 GB SSD;
nested virtualization is technically possible but unsupported. Reclaimed disk is an
observation to measure, not that documented capacity guarantee.
[Runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[nested virtualization limits](https://docs.github.com/en/actions/concepts/runners/github-hosted-runners).

The existing hosted native-install workflow allocates 6 GiB to Windows. Its retained
QEMU arguments explicitly mask `vmx`. A new workflow must not inherit that CPU
configuration. `/dev/kvm` existence proves neither usable KVM nor another nesting
level: this path is Azure host → hosted Linux → QEMU Windows → WHPX Linux.

Collect successful bounded observations of CPU vendor and flags, actual KVM open
and capability ioctls, the applicable `kvm_intel`/`kvm_amd` nested parameter, and
QEMU's expanded proposed CPU model. Require Intel VMX/EPT or AMD SVM/NPT exposure
and enabled nesting. Preserve exact actual outer QEMU argv and Windows processor
observations. Unknown capability refuses before installation. Do not reload host
modules or change global networking. The Linux KVM documentation explains nested
CPU exposure; it does not guarantee this hosted platform's third-level guest.
[KVM nesting](https://docs.kernel.org/virt/kvm/x86/running-nested-guests.html).

Proposed first experiment: outer Windows 8 GiB and 4 vCPUs, explicitly verified after
QEMU starts. Current managed code then allocates the builder 3072 MiB/2 vCPUs and
the desktop 4096 MiB/3 vCPUs. Its fresh preparation admission requires at least 6 GiB
host RAM. These allocations do not prove responsiveness. Record host MemAvailable
before launch and enforce the existing host reserve throughout execution.

Separate guest virtual capacity from physical backing space:

- Experimental target/scratch/reserve is 32+8+8 = 48 GiB measured Windows free space.
  An 80 GiB outer disk may admit this after Windows Setup only if the actual query passes.
- Shipping conservative target/scratch/reserve is 40+40+8 = 88 GiB. The current
  80 GiB outer disk cannot admit it; qualification needs a larger outer disk and
  at least 88 GiB measured Windows free space.
- For the first 32/8 experiment, reserve physical host space for the full 40 GiB
  target/scratch allocation, Windows allocation, installer ISO, signed runtime,
  OCI content and artifacts. A proposed 84 GiB post-reclaim admission budget covers
  40+20+6+2+1+4+8 GiB, with 3 GiB remaining margin. These are provisioning allowances,
  not measured minima; refuse if measured inputs exceed them or the host lacks space.
  Keep a bounded host free-space guard. Sparse image size or the earlier sampled
  allocation peak cannot substitute for available physical backing space.

If a standard runner does not meet these gates, report an infrastructure refusal
and use an explicitly approved larger runner. Do not overcommit or shrink the
profile merely to obtain a green marker.

## Windows and WHPX qualification

OEM owns fresh-fixture feature preparation. Require successful typed observations
of `HypervisorPlatform` Enabled, not EnablePending, processor virtualization/SLAT
fields and hypervisor presence. Require successful `WHvGetCapability` HRESULT and
its HypervisorPresent value. These are prerequisites, not proof of the target guest.
[WHvGetCapability](https://learn.microsoft.com/en-us/virtualization/api/hypervisor-platform/funcs/whvgetcapability).

Enable only the feature required by the reviewed product source. An authorized fresh
Windows restart must have positive Windows identity and a changed, then stable,
LastBootUpTime, the same outer VM identity and no pending servicing. Do not enable
broad Hyper-V feature sets or modify the existing fixture.

Retain the managed runtime's actual guest-code WHPX probe and signed bundle verification.
The measured pinned runtime requires `whpx,kernel-irqchip=off`; its successful probe
passes that exact accelerator to both preparation and desktop launch. No TCG fallback.
A probe timeout is inconclusive. An API partition setup or boot-sector marker still
cannot establish a working target desktop.
[Windows partition setup](https://learn.microsoft.com/en-us/virtualization/api/hypervisor-platform/funcs/whvsetuppartition).

## Product acceptance and missing source contracts

Launch the actual engine and control panel in the ordinary interactive Windows session.
Exercise their real PrepareVM action with the selected immutable image and private
account input. Do not launch GTK from SYSTEM/session 0 and call it a visible window.
Require the actual typed builder result bound to this run/install/image/GPT/account,
clean helper termination, persistent final disk, and signed firmware/runtime identity.

Next require a real Windows GTK VM window and successful Linux identity, current boot,
ordinary-user GNOME session and editor availability. The derived image has no QGA;
the managed engine currently has private QMP on stdio and no inner guest test channel.
Therefore the existing Documents GUI helper cannot simply be pointed at it. A reviewed
source contract is required before claiming automated desktop acceptance:

1. Engine-owned, bounded test observation/control routing with run/install/disk
   correlation; keep QMP ownership in the managed engine and expose only scoped
   test operations. Preserve the global image lock, kill-on-close job and environment.
2. Current guest observations through an explicit test-only channel, or an equivalent
   reviewed GUI observation mechanism: successful OS/boot identity, session UID,
   actual editor executable/window/accessibility state, and readable file/mount facts.
   If this changes the image/helper, rebuild and bind the new signed manifest/profile;
   do not pretend the old digest proves it. Installing unrestricted QGA is not implied.
3. GUI key/pointer input routed to the actual nested display. Create a unique text
   document through the ordinary user's editor, save, close and reopen it; assert
   the actual rendered text and editor state. Read-only shell checks may inspect the
   saved bytes, but must never create or edit the tested file.
4. Call the real StopVM; require reviewed guest-shutdown event and process exit.
   Call BootInVM with the same disk and firmware variables, observe a different
   positive Linux boot, log in and reopen the same document in the GUI. Verify exact
   nonce bytes, user identity and current mount ancestry. Capture real framebuffers
   and semantic receipts. A screenshot file or process liveness alone is insufficient.

`GetVMState.desktopReady` must remain false until an implemented current observation
establishes that contract. Native promotion of this same installed system is a later
separate gate; this desktop acceptance cannot claim it.

## File ownership and review sequence

Runner: new `.github/workflows/vm-first-hosted.yml` and `tests/e2e/vm-first/` host
qualification, bounded orchestration, artifacts and GUI acceptance. OEM: fresh Windows
feature/API observations and reboot qualification. Engine/native-shell owner: matching
RPC test actions, managed display routing and correlated observations. Deployer/helper
owner: signed builder/image observation contract if required. None edits preserved
capacity-trial files or active native acceptance source.

Before one authorized fresh run, require exact candidate normal CI and actual consumer
counterexamples: CPU extension masked, disabled nesting, unavailable WHPX, failed command
with plausible stdout, pending reboot, RAM clamp, insufficient physical/guest space,
wrong signed closure, missing editor, absent interactive session, stale/cross-run receipt,
GUI save failure, unchanged boot and changed disk/firmware identity. Each must refuse.
Record the exact candidate, runtime/image/helper hashes, actual outer argv and all
current-run evidence. Keep #178 open until the actual desktop/persistence gate passes.
