# wootc documentation

The [repository README](../README.md) explains the product and where to get it;
this index helps you find operating instructions, contracts, acceptance
evidence, and design history. A design or release-note filename is not proof
that its behavior ships. Use [verification status](status.md) and
[release instructions](RELEASING.md) for current decisions; dated experiments
and plans are context, not current operating instructions.

## Start here

- [Start here](getting-started.md) — download and open wootc.
- [User guide](user-guide.md) — use the migrated system and return to Windows.
- [Manual tests](manual-testing.md) — pre-flight checks for real hardware.
- [Verification status](status.md) — proven matrix cells and their evidence.
- [Philosophy](philosophy.md) — product goals and decision rules.

### Choose an entry point

| Reader | Read first | Then |
|---|---|---|
| End user | [Getting started](getting-started.md) | [User guide](user-guide.md), or [Coming from WSL](wsl-migration.md) |
| Contributor | [Contributing](../CONTRIBUTING.md), then [AGENTS.md](../AGENTS.md) | [Agent lessons](agent-lessons.md) before harness/deployer changes; [native shell contract](winui-shell.md#current-stdio-protocol-reference) for Go/WinUI integration |
| Maintainer/reviewer | [Verification status](status.md) | [Release instructions](RELEASING.md), [truth-pass record](docs-truth-pass.md), [roadmap](../ROADMAP.md) |
| Distro packager | [Distro adoption](distro-adoption.md) | [Brand distribution](branding-and-distribution.md), [upstream blessings](upstream-blessings.md), [backend contract](backend-contract.md) |
| IT evaluator | [IT-admin quick start](it-admin-quick-start.md) | [Manual testing](manual-testing.md), [destructive paths](destructive-paths.md); this is not a fleet-management product |

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
- [First-boot evidence](firstboot-evidence.md) — observed guest identity and completion records.
- [WSL migration](wsl-migration.md) — manual transfer boundaries; no automatic WSL distro or account import.
- [IT-admin quick start](it-admin-quick-start.md) — bounded single-machine evaluation, not fleet rollout.
- [Adoption outreach](adoption-outreach.md) — approval-gated invitations and scenario briefs, not claimed success stories.
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
- [v0.3.0-beta release notes](release-notes-v0.3.0-beta.md) — draft release material; consult tags and release evidence before you call it shipped.
- [v1.0.0 release notes](release-notes-v1.0.0.md) — release goals and evidence checklist, not a shipped-version claim.

## Document collections

- [`adr/`](adr/) — architecture decision records.
  Includes [phase-1 architecture](adr/0001-phase1-first-architecture.md),
  [hardware matching](adr/0002-hardware-preflight-bootc-matching.md),
  [OneDrive placeholders](adr/0003-onedrive-files-on-demand-migration.md),
  [composefs/kernel matching](adr/0004-composefs-kernel-module-matching.md),
  the [VM-first correction](adr/0004-restore-vm-first-product.md), and
  [session-envelope unlock](adr/0005-session-envelope-unlock.md) (approval pending).
- [`specs/`](specs/) — detailed migration proposals.
  Read [enterprise migration](specs/enterprise-migration.md) and
  [migration extensions](specs/migration-extensions.md) as proposals unless an
  implementation and its acceptance evidence are explicitly named.
- [`experiments/`](experiments/) — dated research notes and implementation experiments.
- [`evidence/`](evidence/) — checked-in evidence summaries.
- [`experiments/evidence/`](experiments/evidence/) — experiment artifacts and provenance.
- [`screenshots/`](screenshots/) — UI walkthrough images.

