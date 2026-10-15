# Plan to qualify VM-first on a hosted runner — 2026-09-27

This plan serves #178. I did not start a VM for this review.
The preserved guest and its disk, TPM and CPU remain unchanged.
Its QGA cannot connect. This does not prove the identity of Windows or a usable desktop.
The BitLocker acceptance tests a separate native path.

## Sources

Start an isolated candidate from current main. Use the same managed engine.
Do not replace its actions with a QEMU command from the test rig.
The old test for Phase1 stages a native install. It cannot qualify this journey.

| Source | Reviewed head | Purpose |
|---|---|---|
| #418 | `e85f9d6fa9cb03fe61623e76485349c878e8d47f` | Persistent raw disk, firmware variables, signed runtime, process ownership |
| #419 | `4fb714534c21aea0a1241e9c4efc05d0b243c242` | Verified Windows runtime package and extraction |
| #422 | `5168dd5f9ea6ee96f64f235fdefd7b13913827a9` | Profile bound to image and runtime |
| #419/#418 shared base | `c7ff613a2380d13f721d0292ebf3c973f57b20d7` | Neither reviewed head contains the other |
| #418/#422 shared base | `14b5365fdb3eef37055d1523d18688b76452d346` | Latest #418 head is not contained in #422 |

These branches overlap. Inspect their ancestry and merge each missing change once.
Resolve their shared files. Then test the real native shell and engine RPC connection.

Preserve the three edits in `/tmp/wootc-capacity-trial`.
The proposed profile has these exact identities:

| Field | Value |
|---|---|
| Image | `ttl.sh/2e6295b0-50ea-42b2-838a-57df8a1022be@sha256:4562f4f0fde8cc0ba49e7ce627be2ba35d803c9aa768e79220a1a58c3b0d148b` |
| Runtime manifest | `48cbafea9f469e195108f9fcb304101a69423cc8193f87fbd540ac813214c8c3` |
| Current registry HEAD | HTTP 200; exact digest above; no image pull |
| Image change | Matching GNOME RPM added; retain its provenance |
| Release selection | Profile registry and build-time selector stay empty without approval |

TTL availability is temporary. Check it again before the build.
Refuse expired content or changed bytes. Do not substitute a mutable tag.

The experiment on Linux proved installation and manual persistence.
I created its file through a shell. It did not prove the editor journey on Windows.

## Host prerequisites

Use a fresh workflow and owned storage. First run the read-only stage.
A successful stage does not authorize a VM launch.

GitHub documents 4 CPUs, 16 GB RAM and 14 GB SSD for standard Linux runners in public repositories.
Nested virtualization is possible but unsupported.
[Runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[platform limits](https://docs.github.com/en/actions/concepts/runners/github-hosted-runners).

The native hosted workflow gives Windows 6 GiB. The retained command for QEMU masks VMX.
The fresh path needs a different, reviewed CPU contract.
The path has four levels: Azure, hosted Linux, Windows, then Linux through WHPX.
The presence of KVM cannot qualify all four.

| Required host observation | Refusal |
|---|---|
| CPU vendor and flags on every observed processor | Unknown vendor, missing VMX/EPT or SVM/NPT |
| Applicable KVM module parameter | Nesting disabled or unknown |
| Successful KVM API and capability ioctls | Access denied, error, wrong API or absent capability |
| Exact proposed CPU argument | No explicit extension, duplicate option or contradictory mask |
| Future expanded QEMU model and actual argv | Proposed argument cannot substitute for actual launch evidence |
| Available RAM and physical space | Missing observation or capacity below admission |

Do not reload host modules or change global networks.
The guide for KVM describes exposure of CPU extensions. It does not guarantee this hosted path.
[KVM guide](https://docs.kernel.org/virt/kvm/x86/running-nested-guests.html).

## Resources

This plan proposes allocations. It does not prove responsiveness.
Measure the actual allocation after launch and retain the result.
Keep the existing reserve for the host throughout execution.

| Resource | Proposed first experiment | Qualification limit |
|---|---|---|
| Outer Windows | 8 GiB RAM, 4 vCPUs | Explicit override; refuse a clamped allocation |
| Managed builder | 3072 MiB, 2 vCPUs | Current #418 allocation |
| Managed desktop | 4096 MiB, 3 vCPUs | Current budget for this outer Windows allocation |
| Host RAM | At least 16,000,000,000 bytes total and 9.5 GiB available | Read-only stage gate |
| Experimental guest free space | 32+8+8 = 48 GiB | Actual Windows free-space query required |
| Conservative guest free space | 40+40+8 = 88 GiB | Current 80 GiB outer disk cannot admit this profile |
| Physical host free space | Proposed 84 GiB admission | Actual available backing space; never sparse file capacity |

The proposed budget allows 40 GiB for target and scratch, and 20 GiB for Windows.
It allows 6 GiB for ISO, 2 GiB for OCI, 1 GiB for runtime, and 4 GiB for artifacts.
It also reserves 8 GiB, with 3 GiB margin.

These are allowances, not measured minima.
Refuse if the actual inputs are larger. Refuse if the host lacks this space.
The peak in a sample cannot substitute for capacity.
A larger runner needs explicit approval if the standard runner fails.

## Windows and WHPX

OEM prepares features on the fresh fixture.
Only enable the feature required by the reviewed source.
Do not change the existing fixture or enable broad feature sets.

| Observation | Required result |
|---|---|
| Successful feature query | HypervisorPlatform Enabled; EnablePending refuses |
| Processor and hypervisor facts | Typed virtualization, SLAT and hypervisor fields |
| WHvGetCapability | Successful HRESULT and HypervisorPresent true |
| Authorized Windows restart | Positive Windows identity; changed then stable LastBootUpTime; same outer identity; no pending servicing |
| Signed managed runtime | Exact verified bundle and firmware |
| Actual guest-code probe | Successful WHPX execution; no TCG fallback; timeout is inconclusive |
| Pinned accelerator | `whpx,kernel-irqchip=off` passed to preparation and desktop |

Availability of the API cannot prove the target desktop.
A disposable partition test or boot-sector marker also cannot prove it.
[Capability API](https://learn.microsoft.com/en-us/virtualization/api/hypervisor-platform/funcs/whvgetcapability),
[partition API](https://learn.microsoft.com/en-us/virtualization/api/hypervisor-platform/funcs/whvsetuppartition).

## Desktop acceptance

Launch the actual engine and control panel in the ordinary Windows session.
Exercise the real PrepareVM action. Keep account input private.
A GTK process in SYSTEM session 0 cannot prove a visible desktop.
The gate needs a current result bound to run, install, image, GPT and account.

The helper must stop cleanly. The final disk must persist.

The derived image has no QGA. The engine owns QMP through private stdin/stdout pipes.
There is no channel for tests in the guest. The existing helper for Documents cannot test this VM.
A scoped contract needs review before automated desktop acceptance.

| Source contract | Required proof |
|---|---|
| Engine route | Bounded test actions bound to run/install/session/disk; existing lock and process ownership retained |
| Guest semantics | Positive OS/boot identity; ordinary user; actual GNOME/editor process, window and accessible text; current mount facts |
| Image/helper change | Explicit review, rebuilt signed manifest and new profile identity |
| GUI input | Type a unique document in the actual editor; save, close, reopen; assert rendered text and editor state |
| Independent file check | Read-only bytes/hash check; shell must not create or edit the tested file |
| Restart | Real StopVM; guest-shutdown event and process exit; real BootInVM with same disk and firmware variables |
| Persistence | New positive Linux boot; same user; reopen document in GUI; exact nonce and current mount ancestry |
| Evidence | Actual framebuffer plus semantic receipts; screenshot existence alone cannot pass |

Keep `desktopReady` false until current observations establish its contract.
Native promotion of the same system is a separate later gate.

## Source stage and display route

`qualify-host.py` only queries the host and writes a receipt. It never calls CREATE_VM.
Observation failure refuses.

The manual workflow does not install Windows or reclaim disk.
It does not change KVM permissions. A denied query needs separate review.
The external deadline is 30 seconds. A missing receipt fails the artifact step.

PR CI runs the consumer controls without the host probe.

| Receipt field | Meaning |
|---|---|
| `outerCpuProposed` | Proposed argument only |
| `outerCpuExpandedObserved` | Null until a separate actual observation exists |
| `windowsWhpxQualified` | False in this stage |
| `guestExecutionQualified` | False in this stage |
| `desktopQualified` | False in this stage |

The existing `qmpClient` owns inherited pipes and correlates command IDs.
It discards the bodies of replies today. Extend that client; do not add another listener.
Use bounded typed replies for query-status, query-mice, screendump and input-send-event.
Reject failed, missing, duplicate or mismatched replies.

Serialize test actions with lifecycle actions. Refuse states for stop or recovery.

The engine selects a private capture path. The caller cannot provide arbitrary paths or commands.
Bind capture hashes to run, install and session identity.

Successful input through QMP cannot prove the state of the editor. A Windows observer must establish the actual GTK
window, process and foreground relation. Guest semantics still need a separate approved contract.
Do not install an unrestricted guest agent.

## Ownership and counterexamples

| Owner | Scope |
|---|---|
| Runner | New hosted workflow, host qualification, bounded orchestration, artifacts and GUI acceptance |
| OEM | Fresh Windows feature/API observations and reboot qualification |
| Engine/native shell | Matching RPC actions and scoped display route |
| Deployer/helper | Signed guest observation contract if required |

Before a fresh run, pass exact CI and actual consumer counterexamples.
Refuse masked extensions or unavailable WHPX.
Refuse failed commands with plausible output, RAM clamps and insufficient space.
Refuse if nested virtualization is disabled or the host still needs a reboot.

Wrong signed content, absent editor/session, stale receipts and failed GUI saves must refuse.
Unchanged boot or changed disk/firmware identity must refuse.
QMP success without current editor observations must not qualify a desktop.
Keep #178 open until the actual desktop and persistence gate passes.
