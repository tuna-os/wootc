# wootc documentation

This directory contains current user guidance, engineering references, release
material, and historical investigations. Start with the first section, then
use topic sections for deeper detail. Documents marked **historical** record a
completed investigation or an earlier plan; they are not current operating
instructions.

## Start here

- [Start here](getting-started.md) — download and open wootc.
- [User guide](user-guide.md) — use the migrated system and return to Windows.
- [Manual tests](manual-testing.md) — pre-flight checks for real hardware.
- [Verification status](status.md) — proven matrix cells and their evidence.
- [Philosophy](philosophy.md) — product goals and decision rules.

## Product and architecture

- [Specification](SPEC.md) — complete product and protocol requirements.
- [Architecture boundary](architecture-boundary.md) — separates generic migration from bootc-specific code.
- [Backend contract](backend-contract.md) — measured deployment-backend interface.
- [Deployer experience](deployer-experience.md) — deployer screens, states, and recovery behavior.
- [GUI and Phase 1 architecture](gui-phase1-architecture.md) — Windows installer flow.
- [GUI walkthrough](gui-walkthrough.md) — screen-by-screen product flow.
- [Native Windows shell](winui-shell.md) — WinUI 3 status, transport, and cutover plan.
- [Plugin architecture](plugin-architecture.md) — program-migrator plugin design.
- [Session migration](session-migration.md) — copy, relink, and sign-in boundaries.
- [Managed VM](managed-vm.md) — Windows VM lifecycle and ownership.
- [E2E architecture](e2e-architecture.md) — test control plane for hosted runs and boot chain.
- [Non-bootc adoption](non-bootc-adoption.md) — support boundaries for other Linux systems.
- [Distro adoption](distro-adoption.md) — installer adaptation for another distribution.
- [Brand identity](branding.md) — product names and re-skinned builds.
- [Brand distribution](branding-and-distribution.md) — branded installers and offline packages.
- [Branded walkthroughs](branded-walkthroughs.md) — automated visual walkthroughs for each brand.

## Trust, storage, and recovery

- [Artifact authentication](artifact-authentication.md) — boot-artifact verification.
- [Destructive paths](destructive-paths.md) — inventory of operations that can remove or alter data.
- [NTFS on Linux](ntfs-on-linux.md) — filesystem hazards and mitigations.
- [systemd-boot](systemd-boot.md) — package and trust policy.
- [Windows state trust](windows-state-trust.md) — evidence required before Windows state changes.
- [VHDX exploration](vhdx-exploration.md) — dynamic root-disk investigation.
- [Borrowed from Libertix](borrowed-from-libertix.md) — adopted boot-chain and recovery designs.
- [Upstream blessings](upstream-blessings.md) — upstream provenance and permissions.

## Verification, testing, and release

- [Verification ladder](milestones.md) — phase-by-phase evidence gates.
- [Release instructions](RELEASING.md) — green-gated release process.
- [Alpha adopter program](alpha-adopter-program.md) — structured early-adopter tests.
- [Pre-filled profiles](prefilled-profile-testing.md) — migration tests with an existing Windows profile.
- [Native GUI soak](soak.md) — shell stability ledger for long runs.
- [Agent lessons](agent-lessons.md) — operational traps from E2E work.
- [Docs truth pass](docs-truth-pass.md) — dated documentation-versus-build checks.

## Plans and historical records

- [Implementation plan](plan.md) — remaining specification coverage.
- [Completion plan](finish-plan.md) — dakota, btrfs, and matrix work.
- [Project review](project-review-2026-09-26.md) — review snapshot from 2026-09-26.
- [dakota return-boot RCA](dakota-return-boot-rca.md) — **historical** Phase-2 hang investigation.
- [Phase-2 attach postmortem](phase2-attach-postmortem.md) — **historical** debugging record.
- [Phase-2 debug plan](phase2-debug-plan.md) — **historical** hypotheses and resolution path.
- [v0.3.0-beta release notes](release-notes-v0.3.0-beta.md) — release record and evidence status.
- [v1.0.0 release notes](release-notes-v1.0.0.md) — release goals and evidence checklist.

## Document collections

- [`adr/`](adr/) — architecture decision records.
- [`specs/`](specs/) — detailed migration proposals.
- [`experiments/`](experiments/) — dated research notes and implementation experiments.
- [`evidence/`](evidence/) — checked-in evidence summaries.
- [`experiments/evidence/`](experiments/evidence/) — experiment artifacts and provenance.
- [`screenshots/`](screenshots/) — UI walkthrough images.

- Use [status.md](status.md) and [release instructions](RELEASING.md) for current verification and release decisions. Use dated plans and investigations for context, not as substitutes for those sources.
