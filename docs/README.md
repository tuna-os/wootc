# wootc Documentation

## Quick navigation

- **End users**: [getting-started.md](getting-started.md), [user-guide.md](user-guide.md)
- **Contributors**: [../CONTRIBUTING.md](../CONTRIBUTING.md), [agent-lessons.md](agent-lessons.md), [SPEC.md](SPEC.md)
- **Release**: [RELEASING.md](RELEASING.md), [status.md](status.md)
- **Packaging**: [branding-and-distribution.md](branding-and-distribution.md), [upstream-blessings.md](upstream-blessings.md)

## User guides

- [getting-started.md](getting-started.md) — Download and first boot
- [user-guide.md](user-guide.md) — Using wootc and reverting
- [philosophy.md](philosophy.md) — Product goals
- [gui-walkthrough.md](gui-walkthrough.md) — Visual tour

## Architecture

- [SPEC.md](SPEC.md) — Full specification
- [architecture-boundary.md](architecture-boundary.md) — Bootc integration
- [e2e-architecture.md](e2e-architecture.md) — Test harness design
- [gui-phase1-architecture.md](gui-phase1-architecture.md) — GUI design
- [plugin-architecture.md](plugin-architecture.md) — Plugin system
- [winui-shell.md](winui-shell.md) — WinUI 3 shell design

## Development

- [agent-lessons.md](agent-lessons.md) — E2E and deployer traps
- [manual-testing.md](manual-testing.md) — Pre-flight checklist
- [status.md](status.md) — Test matrix and known issues
- [prefilled-profile-testing.md](prefilled-profile-testing.md) — Profile testing
- [ntfs-on-linux.md](ntfs-on-linux.md) — NTFS hazards

## Implementation

- [session-migration.md](session-migration.md) — Browser/app state migration
- [destructive-paths.md](destructive-paths.md) — Reversibility gates
- [artifact-authentication.md](artifact-authentication.md) — Boot signing
- [windows-state-trust.md](windows-state-trust.md) — Windows validation
- [systemd-boot.md](systemd-boot.md) — Boot configuration
- [borrowed-from-libertix.md](borrowed-from-libertix.md) — Boot chain designs

## Release

- [RELEASING.md](RELEASING.md) — Release process
- [release-notes-v0.3.0-beta.md](release-notes-v0.3.0-beta.md) — v0.3.0-beta notes
- [branding-and-distribution.md](branding-and-distribution.md) — Branding strategy
- [branding.md](branding.md) — Brand guidelines
- [upstream-blessings.md](upstream-blessings.md) — Upstream governance
- [distro-adoption.md](distro-adoption.md) — Distributor guide

## Planning

- [../ROADMAP.md](../ROADMAP.md) — Roadmap and milestones
- [milestones.md](milestones.md) — Milestone definitions
- [plan.md](plan.md) — Long-term strategy
- [finish-plan.md](finish-plan.md) — Path to 1.0
- [soak.md](soak.md) — Soak testing

## Architecture decisions

See `adr/` for design records:

- [adr/0001-phase1-first-architecture.md](adr/0001-phase1-first-architecture.md) — VM-first design
- [adr/0002-hardware-preflight-bootc-matching.md](adr/0002-hardware-preflight-bootc-matching.md) — Hardware check
- [adr/0003-onedrive-files-on-demand-migration.md](adr/0003-onedrive-files-on-demand-migration.md) — OneDrive migration
- [adr/0004-composefs-kernel-module-matching.md](adr/0004-composefs-kernel-module-matching.md) — composefs matching
- [adr/0004-restore-vm-first-product.md](adr/0004-restore-vm-first-product.md) — VM-first restoration

## Migration

- [specs/enterprise-migration.md](specs/enterprise-migration.md) — Enterprise use cases
- [specs/migration-extensions.md](specs/migration-extensions.md) — Plugin extensions
- [non-bootc-adoption.md](non-bootc-adoption.md) — Non-bootc images

## Other

- [alpha-adopter-program.md](alpha-adopter-program.md) — Early adopters
- [deployer-experience.md](deployer-experience.md) — Deployer UX
- [phase2-attach-postmortem.md](phase2-attach-postmortem.md) — Phase 2 lessons
- [phase2-debug-plan.md](phase2-debug-plan.md) — Phase 2 debug strategy
- [project-review-2026-09-26.md](project-review-2026-09-26.md) — Project status

## Experiments

- [experiments/vm-first-2026-09-26.md](experiments/vm-first-2026-09-26.md) — VM-first tests
- [experiments/vm-first-hosted-qualification-2026-09-27.md](experiments/vm-first-hosted-qualification-2026-09-27.md) — Hosted VM tests
- [experiments/vm-helper-2026-09-26.md](experiments/vm-helper-2026-09-26.md) — VM helper tests
- [experiments/vm-capacity-recovery-2026-09-27.md](experiments/vm-capacity-recovery-2026-09-27.md) — Capacity recovery
- [experiments/artifact-auth-2026-09-27.md](experiments/artifact-auth-2026-09-27.md) — Artifact auth
- [experiments/classic-offline-prerequisites.md](experiments/classic-offline-prerequisites.md) — Offline install

## Evidence

- [evidence/2026-09-27-bitlocker-readiness.md](evidence/2026-09-27-bitlocker-readiness.md) — BitLocker validation

## Maintenance

- [docs-truth-pass.md](docs-truth-pass.md) — Documentation audit

---

## Contributing to docs

1. Create an ADR for design decisions (copy [adr/0001-phase1-first-architecture.md](adr/0001-phase1-first-architecture.md))
2. Keep docs in sync with code
3. Link to related docs
4. Update this index if you add files
