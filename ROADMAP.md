# wootc Roadmap — the road to 1.0

**Last updated**: 2026-08-22 | **Maintainer**: tuna-os (hanthor)

---

## Mission

Make it as easy as possible for **non-technical Windows users** to migrate to Linux **without losing any of their data**. wootc installs a real, image-based bootc Linux system into a single `root.disk` file on the existing Windows NTFS volume — no repartitioning, no backups required, no point of no return. Every decision is weighed against: *would a nervous Windows user get through this without fear or data loss?*

wootc is the org's **conversion front door** — the Windows-hosted complement to the bootc-installer / tuna-installer family, driving [fisherman](https://github.com/projectbluefin/fisherman) under the hood. One engine ships as five installers: generic **wootc**, and branded builds for **TunaOS**, **Bluefin**, **Aurora**, and **Bazzite** (`docs/branding-and-distribution.md`).

## What 1.0 means

1.0 is not a feature count — it is the North Star made checkable:

1. **The download-to-desktop journey needs no instructions beyond the app.** A non-technical user installs (winget or one exe), reboots once, lands in Linux, finds their files, and can get back to Windows — guided entirely by what's on screen.
2. **Zero known data-loss classes.** Every destructive path is double-gated, reversible, and exercised by the matrix; uninstall provably restores the machine.
3. **Evidence, not claims.** Full matrix green (BitLocker and offline included), a 30-day soak of green nightlies, and a body of real-hardware reports with no data-loss incidents.
4. **A trustworthy first impression.** Signed binaries (no SmartScreen wall), a stable winget package, and branded installers blessed by their upstream projects.

Everything below is sequenced toward those four sentences.

---

## Current status (2026-08-22)

**Landed** (all on `main`, all matrix-exercised):
- GUI-driven Phase 1 → 2 → 3 ladder proven on `bluefin:lts`; el10 Phase-2 class fixed; btrfs and BitLocker-refusal cells green.
- **Release automation, three channels**: E2E-gated tagged releases (cuttable from a dispatch input — no tag-push rights needed), auto pre-releases from every green nightly, manual pre-releases. Every release ships all five brand exes + deployer boot artifacts + `SHA256SUMS`.
- **Branding system with real assets** (marks, typefaces, deep themes from each project's published branding), automated per-brand screenshot walkthroughs (`docs/branded-walkthroughs.md`), `just` brand args for local/manual testing.
- **Offline-first core**: Windows-side digest-verified OCI pre-download, deployer bundle ingest, settled-hook start with bounded network wait. Wi-Fi-only laptops install with zero deploy-time network via branded builds / `WOOTC_PRELOAD=1`.
- **North Star UX wave**: Windows on the boot menu, one-shot re-arm, calm product boots with honest copy, first-login welcome + Windows-drive bookmark, Add/Remove entry, uninstall that restores machine state, `docs/getting-started.md` + `docs/manual-testing.md`.
- winget packaging (`TunaOS.wootc`) with auto-submission on full releases (pending the one-time `WINGET_TOKEN` secret).

**In flight**: the first tagged release `v0.1.0-alpha.1` is executing its E2E gate. The nightly auto-release channel has fired end-to-end once already.

**Known defects with owners**: dakota Phase-2 first-boot hang (#209) · profile-migration edge cases (#197) · offline bundle E2E proof pending (#196 follow-ups) · session token rewrap unfinished, honestly labeled (#1) · console window flash (#179).

---

## The version ladder

Each milestone has a tracking issue carrying its live task list. A milestone ships when its checklist is empty and its gate evidence exists — dates are forecasts, gates are not.

### v0.1.0-alpha — "It exists" *(gate running now)*
The first complete release: five brand installers + boot artifacts + SHA256SUMS, E2E-gated, `releases/latest` resolving so plain online installs work. Nightly auto pre-releases keep it fresh without human hands.

### v0.2.0-alpha — "Proven on real hardware" *(tracking: milestone issue M2)*
The VM has been the world so far; this milestone makes real laptops the evidence source.
- Maintainer + early-tester manual runs per `docs/manual-testing.md`, with a field-report issue template; every report triaged to green/fixed/filed.
- Offline proof: `offline=on` matrix axis (`-nic none`), then `preloadImage` default-on for the generic build.
- dakota Phase-2 hang (#209) root-caused; catalog statuses kept honest (demote before excusing).
- No console flash on launch (#179) — the first second must look intentional.
- Harness reliability: QGA-channel loss classified and retried, WU neutralization proven across editions.
- First winget submission accepted upstream.

### v0.3.0-beta — "The whole matrix, honestly" *(tracking: milestone issue M3)*
Beta means the support policy stops saying "alpha" because the evidence exists.
- Full-tier matrix green: every green-status catalog image × win10/11 Pro (+ Enterprise/LTSC cells where media allows).
- **BitLocker path (#34) green** → `BitLockerSupported` flips on for beta.
- Profile-migration edge cases (#197): non-Latin usernames, localized built-in accounts, UAC identity, volume-label ownership.
- Each branded installer through at least one full E2E (Bazzite/Aurora/Bluefin cells join the matrix as their images prove out).
- Upstream blessings: Universal Blue / Bazzite / Aurora sign-off on marks + winget namespaces for branded distribution.
- Session migration (#1): target-side rewrap lands with its per-service test matrix, **or** the feature ships visibly labeled "staged, re-link on Linux" — no silent promises.

### v0.9.0-rc — "Ship-shaped" *(tracking: milestone issue M4)*
- **Code signing** (EV cert / Azure Trusted Signing): kills the SmartScreen wall — the single biggest first-impression fix, and a spend decision that needs the maintainer.
- Try-in-VM (#178) productized (QEMU bundle in the release) or explicitly cut from 1.0.
- Program-migrator plugin architecture (#203): interface decision made; in or out of 1.0 scope, documented either way.
- Docs complete and truthful end-to-end; walkthrough imagery regenerated from the shipping build.
- Soak begins: consecutive green nightlies counting toward the 1.0 gate, release-blocking regressions only.

### v1.0.0 — "The North Star, checkable" *(tracking: milestone issue M5)*
The four criteria at the top of this file, verified: 30 days of green nightlies, the real-hardware report corpus with zero data-loss incidents, signed + winget-stable binaries, blessed brands. Cut from the soak's final green SHA.

---

## Standing technical debt

| Item | Issue | Priority |
|------|-------|----------|
| Session token rewrap, target side | #1 | P1 (beta gate) |
| Program migrator plugin architecture | #203 | P2 (rc decision) |
| E2E runs as systemd user units instead of nohup jobs | #57 | P2 |

## How to contribute

See [CONTRIBUTING.md](./CONTRIBUTING.md). Prefer tasks tied to a red/unverified matrix cell or an open milestone checklist item — evidence that turns a claim green beats untested feature breadth. The milestone tracking issues are the live task boards.

---
*Refreshed 2026-08-22 against current `main` (resolves #201). Refine with maintainer input.*
