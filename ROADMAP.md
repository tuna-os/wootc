# wootc Roadmap

**Last updated**: 2026-08-11 | **Maintainer**: tuna-os (hanthor)

---

## Mission

Make it as easy as possible for **non-technical Windows users** to migrate to Linux **without losing any of their data**. wootc installs a real, image-based bootc Linux system into a single `root.disk` file on the existing Windows NTFS volume — no repartitioning, no backups, no point of no return. Every decision is weighed against: *would a nervous Windows user get through this without fear or data loss?*

wootc is the org's **conversion front door**: it is the highest-leverage adoption channel for growing TunaOS beyond the Linux-curious audience. It is the Windows-hosted complement to the bootc-installer / tuna-installer family and drives [fisherman](https://github.com/projectbluefin/fisherman) under the hood.

---

## Current Status (August 2026)

- **Phase 1 (VM Boot)** works end-to-end: Windows 11 → wootc.exe → signed shim → GRUB → deployer initramfs → fisherman `bootc install` into `root.disk` → native Linux. Green E2E baseline (timelapse published per run).
- **Phase 2 (Native Boot)** in progress: GRUB → ntfs3 → losetup bare-metal boot; composefs Phase 2 module-tree correctness open (#78).
- **Phase 3 (Standalone Linux)** future: Windows removed, NTFS dependency eliminated.
- 16 open issues; active daily development (last push 2026-08-11).
- ⚠️ **No LICENSE yet** — multi-component licensing (Go/Wails UI + Fedora/MS-signed boot chain) needs consolidation (#114).
- ⚠️ **No CONTRIBUTING.md at root** — contribution onboarding pending; Hacktoberfest 2026 surface untapped.
- Adopted by the org as the Windows migration on-ramp; tracked in tunaos ROADMAP (Windows installer track).

### Priorities

| Priority | Item | Tracking | Status |
|----------|------|----------|--------|
| P0 | CI reliability: restore fast test tier + required aggregate gate on main | #54, #55 | 🟡 In progress |
| P0 | LICENSE consolidation (multi-component) | #114 | ⬜ Not started |
| P0 | Decompose `installer_windows.go` (~1,700-line God-file, 47 fns) | #110 | ⬜ Not started |
| P0 | Stop committing 2.8MB E2E timelapse media into git history | #87 | ⬜ Not started |
| P1 | Migration UX: session re-link flows, migration dashboards, per-app consent | #1, #2, #3, #7 | 🟡 In progress |
| P1 | Phase 2 boot correctness: composefs boots the deployer's kernel without matching module tree | #78 | 🟡 In progress |
| P1 | User Data Bridge: migrate silently when Linux username differs from Windows profile | #73 | ⬜ Not started |
| P2 | RFC: hardware pre-flight + hardware-aware image matching | #38 | ⬜ Not started |
| P2 | RFC: OneDrive — carry over local files, mirror Files On-Demand | #65 | ⬜ Not started |

---

## Quarterly Goals

### Q3 2026 (July–September) — "Make it safe"

**Theme**: data safety and CI hardening for the conversion funnel.

| Goal | Owner | Tracking | Status |
|------|-------|----------|--------|
| CI: fast test tier restored + aggregate gate on main | ci-maintainer | #54, #55 | 🟡 In progress |
| LICENSE consolidated and published | guide / maintainer | #114 | ⬜ Not started |
| CONTRIBUTING.md + 3–5 good-first-issues (Hacktoberfest 10-01) | strategist / guide | tunaos#1347 | ⬜ Not started |
| Phase 2 composefs boot correctness | architect | #78 | 🟡 In progress |
| Migration dashboard MVP (discover + consent) | architect | #3, #7 | ⬜ Not started |

### Q4 2026 (October–December) — "Make it a channel"

> **Sketch:** graduation flow (Phase 2 → 3), Windows-style mode polish, partner theming/locking, conversion funnel metrics. Move up when Q4 starts.

---

## Technical Debt Backlog

| Item | Issue | Priority | Effort |
|------|-------|----------|--------|
| `installer_windows.go` God-file decomposition (47 fns: partition/ESP/vault/migration) | #110 | P0 | L |
| 26MB of webm/webp blobs in git history (2.8MB per E2E run) | #87 | P0 | M |
| E2E runs as systemd user units instead of nohup jobs | #57 | P1 | S |
| User Data Bridge username mismatch silent no-op | #73 | P1 | S |

---

## How to Contribute

See [CONTRIBUTING.md](./CONTRIBUTING.md) (pending, #114) for development setup and the PR process. Pick an issue labeled `good first issue` or comment on a goal you would like to own.

---
*Maintained by the strategist agent (tuna-os hive) — seed revision, refine with maintainer input.*
