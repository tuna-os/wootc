# wootc Documentation Index

This folder contains 50+ documents covering wootc's architecture, philosophy, testing, release process, and migration strategies. Use this index to find what you need.

**Quick navigation by role:**
- **End users**: Start with [getting-started.md](getting-started.md) and [user-guide.md](user-guide.md)
- **Contributors**: Read [../CONTRIBUTING.md](../CONTRIBUTING.md), then [agent-lessons.md](agent-lessons.md) and [SPEC.md](SPEC.md)
- **Release maintainers**: See [RELEASING.md](RELEASING.md) and [status.md](status.md)
- **Packagers/distributors**: Check [branding-and-distribution.md](branding-and-distribution.md) and [upstream-blessings.md](upstream-blessings.md)

---

## User & Getting Started

| Document | Purpose |
|---|---|
| [getting-started.md](getting-started.md) | Download, first boot, and troubleshooting for end users |
| [user-guide.md](user-guide.md) | Living in the migrated system, and the way back |
| [philosophy.md](philosophy.md) | The North Star and product goals |
| [gui-walkthrough.md](gui-walkthrough.md) | Visual tour of the GUI |

## Architecture & Design

| Document | Purpose |
|---|---|
| [SPEC.md](SPEC.md) | The full specification (implementation contract) |
| [architecture-boundary.md](architecture-boundary.md) | Generic-migration / bootc seam and abstraction points |
| [e2e-architecture.md](e2e-architecture.md) | E2E test harness architecture and design |
| [gui-phase1-architecture.md](gui-phase1-architecture.md) | GUI/WinUI architecture for Phase 1 |
| [backend-contract.md](backend-contract.md) | Backend interface contract |
| [plugin-architecture.md](plugin-architecture.md) | Plugin system architecture |
| [winui-shell.md](winui-shell.md) | WinUI 3 shell migration: architecture and engine protocol |

## Development & Testing

| Document | Purpose |
|---|---|
| [agent-lessons.md](agent-lessons.md) | Traps and gotchas from 60–90 minute VM runs; read before touching E2E/deployer |
| [manual-testing.md](manual-testing.md) | Pre-flight checklist for real-hardware test runs |
| [status.md](status.md) | Current verification matrix, known-good vs. known-red cells |
| [prefilled-profile-testing.md](prefilled-profile-testing.md) | Migration profile testing patterns |
| [ntfs-on-linux.md](ntfs-on-linux.md) | NTFS on Linux: known hazards and design resilience |

## Specific Implementation Topics

| Document | Purpose |
|---|---|
| [session-migration.md](session-migration.md) | Browser/app session migration strategy and state tracking |
| [destructive-paths.md](destructive-paths.md) | Destructive operations, reversibility, and gates |
| [artifact-authentication.md](artifact-authentication.md) | Boot artifact signing and verification |
| [windows-state-trust.md](windows-state-trust.md) | Windows state validation and trust boundaries |
| [systemd-boot.md](systemd-boot.md) | systemd-boot integration and configuration |
| [borrowed-from-libertix.md](borrowed-from-libertix.md) | Six boot-chain and recovery designs, specified against wootc's code |

## Release & Distribution

| Document | Purpose |
|---|---|
| [RELEASING.md](RELEASING.md) | Release process, gates, signing, and automation |
| [release-notes-v0.3.0-beta.md](release-notes-v0.3.0-beta.md) | v0.3.0-beta release notes and changelog |
| [branding-and-distribution.md](branding-and-distribution.md) | One engine, five installers; branding strategy |
| [branding.md](branding.md) | Brand asset guidelines |
| [upstream-blessings.md](upstream-blessings.md) | Upstream project governance and distribution approval |
| [distro-adoption.md](distro-adoption.md) | How distributions can adopt and customize wootc |

## Planning & Roadmap

| Document | Purpose |
|---|---|
| [../ROADMAP.md](../ROADMAP.md) | Project roadmap, milestones, and version ladder (main repo) |
| [milestones.md](milestones.md) | Milestone tracking and definitions |
| [plan.md](plan.md) | Strategic planning and long-term vision |
| [finish-plan.md](finish-plan.md) | Path to release completion and 1.0 |
| [soak.md](soak.md) | Soak testing policy and execution |

## Architecture Decision Records (ADRs)

Design decisions are recorded as ADRs in `adr/`:

| ADR | Title |
|---|---|
| [adr/0001-phase1-first-architecture.md](adr/0001-phase1-first-architecture.md) | Phase 1: VM-first architecture |
| [adr/0002-hardware-preflight-bootc-matching.md](adr/0002-hardware-preflight-bootc-matching.md) | Hardware preflight and bootc image matching |
| [adr/0003-onedrive-files-on-demand-migration.md](adr/0003-onedrive-files-on-demand-migration.md) | OneDrive Files on Demand migration strategy |
| [adr/0004-composefs-kernel-module-matching.md](adr/0004-composefs-kernel-module-matching.md) | composefs kernel module matching |
| [adr/0004-restore-vm-first-product.md](adr/0004-restore-vm-first-product.md) | Restore VM-first product focus (ADR 0004-2) |

## Migration & Integration

| Document | Purpose |
|---|---|
| [specs/enterprise-migration.md](specs/enterprise-migration.md) | Enterprise migration strategy and requirements |
| [specs/migration-extensions.md](specs/migration-extensions.md) | Migration plugin extensions and interfaces |
| [non-bootc-adoption.md](non-bootc-adoption.md) | Non-bootc image adoption and compatibility |

## Development & Maintenance

| Document | Purpose |
|---|---|
| [alpha-adopter-program.md](alpha-adopter-program.md) | Alpha adopter engagement and feedback |
| [deployer-experience.md](deployer-experience.md) | Deployer initramfs user experience |
| [phase2-attach-postmortem.md](phase2-attach-postmortem.md) | Phase 2 attach postmortem and lessons learned |
| [phase2-debug-plan.md](phase2-debug-plan.md) | Phase 2 debugging strategy |
| [project-review-2026-09-26.md](project-review-2026-09-26.md) | Project status review (2026-09-26) |

## Experiments & Investigations

Recent experiments exploring design alternatives and proof-of-concepts live in `experiments/`:

| Document | Purpose |
|---|---|
| [experiments/vm-first-2026-09-26.md](experiments/vm-first-2026-09-26.md) | VM-first product restoration experiments |
| [experiments/vm-first-hosted-qualification-2026-09-27.md](experiments/vm-first-hosted-qualification-2026-09-27.md) | Hosted VM qualification experiments |
| [experiments/vm-helper-2026-09-26.md](experiments/vm-helper-2026-09-26.md) | VM helper testing and preflight |
| [experiments/vm-capacity-recovery-2026-09-27.md](experiments/vm-capacity-recovery-2026-09-27.md) | VM capacity recovery strategies |
| [experiments/artifact-auth-2026-09-27.md](experiments/artifact-auth-2026-09-27.md) | Artifact authentication mechanisms |
| [experiments/classic-offline-prerequisites.md](experiments/classic-offline-prerequisites.md) | Classic offline installation prerequisites |

## Evidence & Validation

Test runs, matrix cells, and proof artifacts are recorded in `evidence/`:

| Document | Purpose |
|---|---|
| [evidence/2026-09-27-bitlocker-readiness.md](evidence/2026-09-27-bitlocker-readiness.md) | BitLocker readiness validation evidence |

## Internal & Maintenance

| Document | Purpose |
|---|---|
| [docs-truth-pass.md](docs-truth-pass.md) | Documentation audit and truth verification |

---

## How to contribute to docs

1. If documenting a new feature or design decision, consider creating an ADR (copy and adapt `adr/0001-phase1-first-architecture.md`)
2. Keep docs in sync with code changes — stale docs are worse than missing docs
3. Link liberally — cross-reference related documents so readers don't get lost
4. Use the relevant section above to guide where a new document belongs
5. Update this index if you add or rename a file
