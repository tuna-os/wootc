# wootc Roadmap

**Last updated**: 2026-08-22 | **Maintainer**: tuna-os (hanthor)

---

## Mission

Make it as easy as possible for **non-technical Windows users** to migrate to Linux **without losing any of their data**. wootc installs a real, image-based bootc Linux system into a single `root.disk` file on the existing Windows NTFS volume — no repartitioning, no backups, no point of no return. Every decision is weighed against: *would a nervous Windows user get through this without fear or data loss?*

wootc is the org's **conversion front door**: it is the highest-leverage adoption channel for growing TunaOS beyond the Linux-curious audience. It is the Windows-hosted complement to the bootc-installer / tuna-installer family and drives [fisherman](https://github.com/projectbluefin/fisherman) under the hood.

---

## Current Status (August 2026)

- The `bluefin:lts` path has completed the GUI-driven Phase 1 → 2 → 3
  verification ladder. The product can arm Windows, deploy into `root.disk`,
  boot native Linux, graduate to a native disk, and preserve seeded user data.
- The broader image/Windows/filesystem matrix is not yet uniformly proven.
  Treat the [README build/test matrix](README.md#buildtest-matrix) as the status
  source of truth; older greens that predate the failure-ledger fix require
  revalidation.
- CI, licensing, contributor guidance, composefs Phase-2 correctness, repository
  media growth, and the Windows installer decomposition have landed (#54, #55,
  #78, #87, #110, #114).
- The E2E-gated release workflow and release policy exist, but **no GitHub
  Release has been published**. The most recent GUI-driven E2E run on 2026-08-21
  failed, so the first alpha is awaiting fresh green evidence rather than more
  feature breadth.
- Active development remains concentrated with the maintainer. The next
  contributor-facing work should be small, evidence-backed tasks that advance
  release confidence.

### Priorities

| Priority | Item | Tracking | Status |
|----------|------|----------|--------|
| P0 | Re-establish a fresh green GUI-driven `bluefin:lts` run on current `main` | #201 | 🟡 In progress |
| P0 | Make the first `v0.1.0-alpha` release/no-release decision from that evidence | #201, [release policy](docs/RELEASING.md) | ⬜ Pending gate |
| P1 | Revalidate the full matrix under the failure-ledger harness; unlock only proven cells | [build/test matrix](README.md#buildtest-matrix) | 🟡 In progress |
| P1 | Keep migration claims evidence-bound while DPAPI token rewrap remains open | #1 | 🟡 In progress |
| P1 | Seed contributor-sized tasks from matrix failures and release-readiness gaps | #201 | ⬜ Not started |
| P2 | Define beta/stable decisions only after alpha evidence and an explicit soak window | [release policy](docs/RELEASING.md) | ⬜ Not started |

---

## Quarterly Goals

### Q3 2026 (July–September) — "Make it safe"

**Theme**: data safety and CI hardening for the conversion funnel.

| Goal | Owner | Tracking | Status |
|------|-------|----------|--------|
| Core repository readiness: CI gate, licenses, contribution guide | maintainers | #54, #55, #114 | ✅ Complete |
| GUI-driven `bluefin:lts` baseline proven | E2E maintainers | [verification ladder](docs/milestones.md) | ✅ Complete |
| Fresh green GUI E2E on release candidate commit | E2E maintainers | #201 | 🟡 In progress |
| First alpha release decision and evidence record | maintainer | #201 | ⬜ Pending gate |
| Contributor task seeding from current release gaps | strategist / guide | #201, tunaos#1347 | ⬜ Not started |

### Q4 2026 (October–December) — "Make it a channel"

> **Sketch:** graduation flow (Phase 2 → 3), Windows-style mode polish, partner theming/locking, conversion funnel metrics. Move up when Q4 starts.

---

## Technical Debt Backlog

| Item | Issue | Priority | Effort |
|------|-------|----------|--------|
| E2E runs as systemd user units instead of nohup jobs | #57 | P1 | S |
| DPAPI token rewrap for Chromium/Electron sessions | #1 | P1 | L |

---

## How to Contribute

See [CONTRIBUTING.md](./CONTRIBUTING.md) for development setup and the PR
process. Prefer tasks tied to a current red/unverified matrix cell or the alpha
release gate; evidence that turns a claim green is more valuable than adding
untested feature breadth.

---
*Maintained by the strategist agent (tuna-os hive) — seed revision, refine with maintainer input.*
