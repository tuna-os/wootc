# wootc Documentation Index

This folder holds 50+ documents about architecture, philosophy, testing, and release. Start with what fits your role.

**By role:**
- **End users**: [getting-started.md](getting-started.md), [user-guide.md](user-guide.md)
- **Contributors**: [../CONTRIBUTING.md](../CONTRIBUTING.md), [agent-lessons.md](agent-lessons.md), [SPEC.md](SPEC.md)
- **Release maintainers**: [RELEASING.md](RELEASING.md), [status.md](status.md)
- **Packagers**: [branding-and-distribution.md](branding-and-distribution.md), [upstream-blessings.md](upstream-blessings.md)

---

## User & Getting Started

| Document | Purpose |
|---|---|
| [getting-started.md](getting-started.md) | Download, first boot, troubleshooting |
| [user-guide.md](user-guide.md) | Using the migrated system |
| [philosophy.md](philosophy.md) | Goals and product vision |
| [gui-walkthrough.md](gui-walkthrough.md) | GUI tour |

## Architecture & Design

| Document | Purpose |
|---|---|
| [SPEC.md](SPEC.md) | Full specification |
| [architecture-boundary.md](architecture-boundary.md) | Migration and bootc boundaries |
| [e2e-architecture.md](e2e-architecture.md) | E2E test design |
| [gui-phase1-architecture.md](gui-phase1-architecture.md) | GUI and WinUI design |
| [backend-contract.md](backend-contract.md) | Backend interface |
| [plugin-architecture.md](plugin-architecture.md) | Plugin system |
| [winui-shell.md](winui-shell.md) | WinUI 3 shell and protocol |

## Development & Testing

| Document | Purpose |
|---|---|
| [agent-lessons.md](agent-lessons.md) | E2E and deployer pitfalls |
| [manual-testing.md](manual-testing.md) | Preflight for hardware tests |
| [status.md](status.md) | Test matrix status |
| [prefilled-profile-testing.md](prefilled-profile-testing.md) | Profile test patterns |
| [ntfs-on-linux.md](ntfs-on-linux.md) | NTFS on Linux risks |

## Implementation Topics

| Document | Purpose |
|---|---|
| [session-migration.md](session-migration.md) | Session and state migration |
| [destructive-paths.md](destructive-paths.md) | Destructive operations and gates |
| [artifact-authentication.md](artifact-authentication.md) | Boot artifact signing |
| [windows-state-trust.md](windows-state-trust.md) | Windows state validation |
| [systemd-boot.md](systemd-boot.md) | systemd-boot setup |
| [borrowed-from-libertix.md](borrowed-from-libertix.md) | Boot and recovery designs |

## Release & Distribution

| Document | Purpose |
|---|---|
| [RELEASING.md](RELEASING.md) | Release process and gates |
| [release-notes-v0.3.0-beta.md](release-notes-v0.3.0-beta.md) | v0.3.0-beta notes |
| [branding-and-distribution.md](branding-and-distribution.md) | Branding and installers |
| [branding.md](branding.md) | Brand guidelines |
| [upstream-blessings.md](upstream-blessings.md) | Upstream governance |
| [distro-adoption.md](distro-adoption.md) | Adopting wootc in distributions |

## Planning & Roadmap

| Document | Purpose |
|---|---|
| [../ROADMAP.md](../ROADMAP.md) | Roadmap and version plan |
| [milestones.md](milestones.md) | Milestone tracking |
| [plan.md](plan.md) | Strategic vision |
| [finish-plan.md](finish-plan.md) | Path to 1.0 |
| [soak.md](soak.md) | Soak testing |

## Architecture Decisions

| ADR | Title |
|---|---|
| [adr/0001-phase1-first-architecture.md](adr/0001-phase1-first-architecture.md) | Phase 1: VM-first |
| [adr/0002-hardware-preflight-bootc-matching.md](adr/0002-hardware-preflight-bootc-matching.md) | Hardware preflight |
| [adr/0003-onedrive-files-on-demand-migration.md](adr/0003-onedrive-files-on-demand-migration.md) | OneDrive migration |
| [adr/0004-composefs-kernel-module-matching.md](adr/0004-composefs-kernel-module-matching.md) | composefs matching |
| [adr/0004-restore-vm-first-product.md](adr/0004-restore-vm-first-product.md) | VM-first restore |

## Migration & Integration

| Document | Purpose |
|---|---|
| [specs/enterprise-migration.md](specs/enterprise-migration.md) | Enterprise migration |
| [specs/migration-extensions.md](specs/migration-extensions.md) | Migration plugins |
| [non-bootc-adoption.md](non-bootc-adoption.md) | Non-bootc images |

## Development & Maintenance

| Document | Purpose |
|---|---|
| [alpha-adopter-program.md](alpha-adopter-program.md) | Alpha feedback |
| [deployer-experience.md](deployer-experience.md) | Deployer UX |
| [phase2-attach-postmortem.md](phase2-attach-postmortem.md) | Phase 2 lessons |
| [phase2-debug-plan.md](phase2-debug-plan.md) | Phase 2 debug |
| [project-review-2026-09-26.md](project-review-2026-09-26.md) | Project review |

## Experiments

| Document | Purpose |
|---|---|
| [experiments/vm-first-2026-09-26.md](experiments/vm-first-2026-09-26.md) | VM-first experiments |
| [experiments/vm-first-hosted-qualification-2026-09-27.md](experiments/vm-first-hosted-qualification-2026-09-27.md) | Hosted VM tests |
| [experiments/vm-helper-2026-09-26.md](experiments/vm-helper-2026-09-26.md) | VM helper tests |
| [experiments/vm-capacity-recovery-2026-09-27.md](experiments/vm-capacity-recovery-2026-09-27.md) | VM capacity tests |
| [experiments/artifact-auth-2026-09-27.md](experiments/artifact-auth-2026-09-27.md) | Artifact auth |
| [experiments/classic-offline-prerequisites.md](experiments/classic-offline-prerequisites.md) | Offline setup |

## Evidence & Validation

| Document | Purpose |
|---|---|
| [evidence/2026-09-27-bitlocker-readiness.md](evidence/2026-09-27-bitlocker-readiness.md) | BitLocker validation |

## Contributing to docs

1. For new features, create an ADR (copy `adr/0001-phase1-first-architecture.md`)
2. Keep docs in sync with code
3. Link to related docs
4. Place docs in the right section
5. Update this index
