# wootc Roadmap — the road to 1.0

**Last updated**: 2026-11-02 | **Maintainer**: tuna-os (hanthor)

---

## Mission

Help **non-technical Windows users** adopt Linux **without losing their data**.
The first experience runs Linux in a VM inside Windows, with a persistent `root.disk`.
Native boot comes later, when the person chooses it, with the same accounts, files, and settings.
Prioritize people with an older laptop or desktop over enterprise features.
Ask of every decision: *can a person understand this on Windows and keep their work safe?*

This is the product goal. Current releases do not yet provide the complete VM-first journey;
[verification status](docs/status.md) records what the evidence proves.

wootc is the org's **conversion front door**. It complements bootc-installer / tuna-installer on Windows and uses [fisherman](https://github.com/tuna-os/fisherman). One engine ships as five installers: generic **wootc**, **TunaOS**, **Bluefin**, **Aurora**, and **Bazzite** (`docs/branding-and-distribution.md`).

## What 1.0 means

1.0 is not a feature count — it is the North Star made checkable:

1. **The app guides the whole journey.** A person without technical skills installs the app and opens Linux inside Windows. They find their selected files. Work survives VM shutdown and restart. Later, the person chooses native boot of that same system, with a route back to Windows. The app explains any Windows restart needed to enable virtualization before preparation begins.
2. **No known causes of data loss.** Every destructive path needs two gates and a reversible action. The matrix exercises each path. Evidence must prove that uninstall restores the machine.
3. **Evidence, not claims.** The full matrix must pass, including BitLocker and offline cases. The soak needs 30 days of green nightlies. Reports from real hardware must show no data loss.
4. **A trustworthy first impression.** Signed binaries must pass the SmartScreen gate on a fresh machine. The winget package must stay stable. Upstream projects must approve their branded installers.

The sequence below serves those four requirements.

---

## Delivery history (recorded 2026-09-17)

The entries below record earlier native-path work. They do not prove the current
build or Phase 1 inside Windows. Use [the status matrix](docs/status.md#buildtest-matrix)
for current verification and [the VM experiments](docs/experiments/vm-first-2026-09-26.md)
for the work to restore the intended first experience.

**Landed on `main`:**
- **v0.3.0-beta milestone work (not released)**: The milestone issue #211 closed on 2026-09-02, but no `v0.3.0-beta` tag or release exists. Earlier work enabled the BitLocker policy and captured numerical keys for recovery. It resolved UAC identity to the interactive user and checked ownership of `wootc-data`. It added migrator plugins, JSON manifest schemas, and a runbook to take back a bad release (#211, #358, #354, #362).
- **Later dependencies and tools**: Wails reached v2.16.0 (#384), and Vite reached v8.3.0 (#382). `golang.org/x/crypto` reached v0.57.0 (#381), and `golang.org/x/sys` reached v0.48.0 (#379). Direct tests cover the DTO generator (#378). The repository adopted the shared English check and Renovate preset (#374, #375).
- Historical runs used the GUI and passed native deployment, Linux boot, and graduation on `bluefin:lts`. Those runs did not launch Linux inside Windows.
- **Release automation, three channels**: Tagged releases need an E2E gate. Dispatch inputs can select a tag without tag-push rights. Green nightlies can produce automatic pre-releases; manual pre-releases also exist. The native cutover code on `main` prepares setup assets, deployer artifacts, one `wootc-legacy.exe` fallback, and signed checksum manifests. This is a build contract, not the asset list of the published `v0.1.0-alpha.1`, which still ships Wails executables.
- **First tagged release shipped**: [`v0.1.0-alpha.1`](https://github.com/tuna-os/wootc/releases/tag/v0.1.0-alpha.1) passed its E2E gate. The release workflow published it on 2026-08-22.
- **Brand assets**: Marks, typefaces, and themes come from each project's published assets. Automatic screenshots show each brand (`docs/branded-walkthroughs.md`). `just` brand arguments support local and manual tests.
- **Offline-first core**: Windows can pre-download OCI data and verify its digest. The deployer ingests that bundle. Its settled hook starts with a bounded wait for the network. Branded builds / `WOOTC_PRELOAD=1` support installation without a network during deployment on Wi-Fi-only laptops.
- **Earlier user experience**: Windows appears on the boot menu, and users can re-arm a one-shot boot. Product boots have calm text. First login offers a welcome and a bookmark to the Windows drive. Add/Remove has an entry. Uninstall tries cleanup; complete restoration still needs proof. Guides exist in `docs/getting-started.md` and `docs/manual-testing.md`.
- The winget package (`TunaOS.wootc`) supports automatic submission on full releases. It still needs the one-time `WINGET_TOKEN` secret.

**In flight**: RC acceptance and signing setup remain incomplete. Phase A of the WinUI migration (#340) added `wootc.exe serve` JSON-RPC. Phases B (#343) and C (#344) contain substantial native implementation and component checks, but their open acceptance trackers do not establish a complete Windows-hosted VM journey.

Phase D (#345) closed on 2026-10-31 after the native packaging cutover merged. The latest full release is still `v0.1.0-alpha.1`; it does not contain native setup assets. The post-cutover Secure Boot authority and publisher-policy defects in #688 block release acceptance. Phase E (#346) must retain the legacy fallback until a clean native release and its audit exist.

**Open verification**: #596 retains the VM-first RC requirement reaffirmed by the maintainer on 2026-10-30. Closing #178 does not supply desktop, persistence, or same-system promotion evidence. Dakota's historical hang tracker #209 and the earlier GUI reliability epic #399 are closed; their old red matrix rows are historical, not proof of a new pass. Session migration remains open under #1 and its target-side import issues.

### Working-tree follow-up — 2026-11-02

The 58 open issues were grouped into these workstreams. This is a source-work
record, not issue closure, a released artifact, or an upgrade of the matrix.

| Workstream / issues | Source work and remaining acceptance boundary |
|---|---|
| Native release: #688, #346, #344, #343, #340, #304 | Release-bound shim authorities/publisher metadata, editable profile mappings and native boot-summary/proof controls. Signed Windows setup/UIA/full-cycle proof and upstream decisions remain required; legacy removal waits. |
| Installation safety: #427, #285, #279, #197 | Canonical fail-closed BitLocker staging/scrubbing, profile collision handling, ordinary-user Documents copying, retained recovery authority and owned uninstall/power state. Real encrypted editing/restart and Windows interruption/restore proof remain required. |
| Sessions: #1, #252, #253, #254, #255, #256, #257, #258, #259, #293, #294, #295, #296, #420 | Consented encrypted-envelope import, bounded Chromium stores, explicit Linux keyring backends, preservation/recovery rules and shared detection. Unsupported formats refuse; Spotify and real authenticated application journeys remain open. ADR 0005 remains proposed. |
| VM-first: #596 | Read-only installed-target boot-input export with identity/hash checks and durable state, plus startup-state repairs. Windows-hosted desktop/persistence acceptance, host promotion preflight and transactional native handoff remain open; export does not arm boot. |
| Hardware/catalog: #576, #574 | Pinned upstream catalog plus explicit consumer policy; target-module/firmware compatibility checks before Windows mutation. Unknown observations warn rather than imply support; real hardware acceptance remains required. |
| Architecture: #588, #587, #545, #518, #380, #297 | Install-policy seams, shared progress catalogue, credential-safe diagnostics, sourceable deployer modules and layer-specific evidence. Broad extraction and full product-layer acceptance are not implied by these boundaries. |
| Documentation: #544, #541, #539, #233 | Contributor/toolchain guidance, categorized index, protocol/consent/grant contracts and current-release truth corrections. Candidate walkthrough and docs-vs-release verification still need the candidate artifact. |
| Release gates: #367, #241, #240, #239, #237, #234, #229, #222, #221, #217, #213, #212, #24 | Native proof producer/strict soak verifier, audit follow-up and release prerequisites. Azure provisioning, winget moderation/token, complete matrix/offline/hardware proof and an actual 30-day soak cannot be replaced by component tests. |
| Adoption: #598, #595, #594, #592, #591, #590, #586, #302 | Approval-gated cohort/outreach, WSL and administrator material. No recruitment, publication, partnership, upstream approval or participant success is claimed. |

---

## The version ladder

Each milestone has an issue with its current task list. A milestone ships when its checklist is empty and its gate evidence exists. Dates are forecasts; gates are requirements.

### v0.1.0-alpha — "It exists" *(shipped 2026-08-22)*
The first complete release passed the E2E gate. It shipped installers for five brands, boot artifacts, and SHA256SUMS. `releases/latest` resolves so plain online installs work. Automatic nightly pre-releases keep it fresh.

### v0.2.0-alpha — "Proven on real hardware" *(tracking: milestone issue M2)*
The VM has been the world so far; this milestone makes real laptops the evidence source.
- Maintainer + early-tester manual runs per `docs/manual-testing.md`, with a field-report issue template; every report triaged to green/fixed/filed.
- Offline proof: `offline=on` matrix axis (`-nic none`), then `preloadImage` default-on for the generic build.
- Re-verify Dakota on the candidate build after the historical Phase-2 hang tracker (#209) closed. Catalog status still requires current acceptance evidence.
- No console flash on launch (#179) — the first second must look intentional.
- Harness reliability: QGA-channel loss classified and retried, WU neutralization proven across editions.
- Upstream must accept the first winget submission.

### v0.3.0-beta — "The whole matrix, honestly" *(planned: milestone issue #211 closed 2026-09-02; no tag or release yet; release notes drafted in docs/release-notes-v0.3.0-beta.md)*
Beta means the support policy stops saying "alpha" because the evidence exists.
- **Full-tier matrix green (#222)**: every green-status catalog image × win10/11 Pro (+ Enterprise/LTSC cells where media allows) proven in `tests/e2e/matrix.tsv` and `app/data/images.json`.
- **BitLocker path (#34, #223) green**: Enable `BitLockerSupported: true` on beta with numerical keys for recovery and dedicated storage volumes.
- **Profile edge cases (#197)**: Non-Latin usernames need the `winuserN` fallback; never silently drop them (#224). Exclude built-in accounts with localized names (#224). Resolve UAC identity to the interactive human, including elevation through another admin (#225). Verify ownership of the `wootc-data` volume label before `RemovePartition` (#225).
- **Branded-installer E2E cells (#226)**: Prove Bazzite, Aurora, and plain Bluefin end-to-end before the catalog assigns `status: green`.
- **Upstream blessings (#227, #319)**: Record the governance framework and decisions in `app/branding/README.md` and `docs/upstream-blessings.md`.
- **Session migration (#1, #228, #347)**: labeled honestly across dashboard, done screen, and docs as staged re-link on Linux.
- **Support-policy audit**: every `GetSupportPolicy` flag traceable to a green matrix row with comprehensive test coverage.

### v0.9.0-rc — "Ship-shaped" *(tracking: milestone issue M4)*
- **Signed binaries**: The maintainer chose `Azure Trusted Signing` (#229). The release workflow can sign with it after the Azure setup in `docs/RELEASING.md`. Verify publisher identity and fresh-machine SmartScreen behavior (#230). A valid signature alone does not guarantee that SmartScreen lets a launch proceed without a prompt.
- **WinUI 3 shell replaces Wails (#340)**: phases B–D must pass their native gates before the RC default changes. Phase E follows a clean native release. The [sequence for the native shell](#native-shell-sequence-and-evidence-357) defines which earlier evidence can carry forward.
- **VM-first (#596, formerly #178)**: Required first experience, reaffirmed by the maintainer on 2026-10-30. Prepare and run the persistent Linux image inside Windows before native boot. [ADR 0004](docs/adr/0004-restore-vm-first-product.md) replaces the #318 deferral; the full Windows-hosted desktop, persistence, and native-promotion gate remains unproved.
- **Migration adapters (#203)**: Discovery and manifests exist. The [extension plan](docs/specs/migration-extensions.md) adds truthful results, transactions, compatibility, and scoped execution before broad support.
- **Boot-chain work from Libertix (#308)**: [Libertix](https://github.com/ekimiateam/libertix) also installs Linux from Windows. It uses real partitions; wootc uses `root.disk`. Its geometry code does not apply, but its reboot designs help. `docs/borrowed-from-libertix.md` defines six items. They cover Secure Boot CA preflight (#322) and recovery guard (#331). They cover evidence of first boot, checked from Windows (#332), and ESP signed-chain refresh (#333). They also need one catalogue of steps with a CI diff (#334) and pinned, signed artifacts (#335).
- Complete the docs and verify their claims end-to-end. Regenerate walkthrough images from the release build.
- Start the soak after its prerequisites pass. Count consecutive nightlies that pass toward 1.0; allow only work on regressions that block release.

### Native shell sequence and evidence (#357)

The WinUI cutover is inside the road to 1.0. Earlier Wails releases can ship
before phase D. They do not start the 1.0 soak. A beta release, when one is
cut, is not proof of the future native product.

| Phase | Place on the ladder | Gate |
|---|---|---|
| A (#342, #348) | Existing engine seam | Preserve the protocol; prove safe disconnect and transport handles |
| B (#343) | RC preparation, preview only | Native projects, authenticated peers, brand packages, clean offline startup |
| C (#344) | RC preparation, preview only | Consumer and VM journey, accessible controls, native UI tests and full cycles |
| D (#345) | RC default change | B and C pass; release uses the native shell and keeps one legacy release |
| E (#346) | After that clean native release, before 1.0 | Remove legacy code only after native gates and the docs audit pass |

**Carry only evidence for unchanged engine code and contracts.**
WinUI needs new proof for UI, transport, identity, setup, accessibility, and the complete journey.
This applies to M2 field reports and M3 matrix rows as well as RC release tests.
Keep earlier reports for diagnosis and component proof; they cannot certify a
replacement UI. Repeat affected journeys on hardware, walks for each brand, and matrix
cells on the native artifact before a new support claim.

The 1.0 soak starts after phase D and all RC prerequisites pass, with a recorded
start date. Only native-shell GUI nightlies on main can qualify. Each row must
name the shell, source SHA, artifact identity, verdict, and proof run.

No Wails row counts toward the native streak. A shell or transport change needs new
proof; do not inherit a streak across it. The ledger in #235 must apply this
rule before #239 can cite 30 days. The [ledger](docs/soak.md) records runs. It has no
recorded start or eligible streak. See [the release gates](docs/RELEASING.md#native-shell-release-gates).

### Scope decisions

#### VM first, native boot later (#178)

The maintainer reaffirmed this direction on 2026-09-26.
Linux must run inside Windows before the person chooses native boot.
Both modes must preserve the same installed system and user work.
PR #318 deferred the fresh builder but treated post-install VM boot as enough.
The actual install still required the native deployer, so that did not meet ADR 0001.
[ADR 0004](docs/adr/0004-restore-vm-first-product.md) records the repair plan and acceptance gates.

The WinUI rewrite must carry this journey. Do not remove the VM surface at cutover.

### v1.0.0 — "The North Star, checkable" *(tracking: milestone issue M5)*
Verify all four criteria at the top of this file. All 30 days of nightlies must pass. Reports from real hardware must show no data loss. Verify signed binaries, a stable winget package, and approved brands. Cut from the final green SHA of the soak.

---

## Standing technical debt

| Item | Issue | Priority |
|------|-------|----------|
| Session token rewrap verification | #1 | P2 (v0.9.0-rc validation; beta gate resolved via staged re-link #347) |
| Migration adapters | #258, #296 | Finish target-side orchestration and truthful import outcomes; the plugin architecture itself was delivered in #354 |
| VM-first persistent Linux inside Windows | #596 | Product priority; acceptance remains required despite #178 closing |

## How to contribute

See [the contribution guide](./CONTRIBUTING.md). Prefer tasks tied to a red or unverified matrix cell or an incomplete milestone checklist. Evidence must support each green claim. Milestone issues contain the current tasks.

---
*History: refresh on 2026-09-17 (resolves #394), WinUI scope on 2026-09-24 (#357), and Libertix scope on 2026-09-26 (#308). Current-claim audit: 2026-09-27 against `323b7ba`. Refine with maintainer input.*
