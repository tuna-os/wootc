## Goal

Clear the 80 open issues and 7 open PRs in tuna-os/wootc in a dependency-safe sequential order, grouped into epics that move the repo toward the 1.0 North Star (ROADMAP.md: v0.2.0-alpha real hardware → v0.9.0-rc ship-shaped → v1.0.0 checkable).

## Success Criteria

- Every open PR is merged or explicitly closed with a recorded reason; `gh pr list --state open` is empty.
- Every open issue is closed by a merged fix, closed as duplicate/wontfix with a comment, or assigned to a dated milestone epic (M2 #210, M4 #212, M5 #213, WinUI #340); no issue left untriaged.
- `main` stays green throughout: `ci.yml` + `ci-tests.yml` fast tier, plus affected BATS suites, pass per work unit.
- No new E2E red introduced: the e2e-gui reliability epic (#399) is the gate for auto-release, so nothing lands that makes it worse.
- The WinUI cutover (#340 phases B–E) has an explicit evidence-carryover rule (#357) before any Wails surface it would invalidate is re-proven.

## Context And Current Facts

- Backlog size (verified 2026-09-26 via `gh issue/pr list`): 80 open issues, 7 open PRs.
- All 7 open PRs report `mergeable: MERGEABLE`, `mergeStateStatus: CLEAN`, all required checks SUCCESS: #401 (ROADMAP WinUI mention), #338 (recovery guard #331), #327 (fault-injection #288), #325 (fresh-machine verification #241), #324 (uninstall restoration #238), #317 (UAC identity #225), #313 (BitLocker beta #223).
- Milestone trackers: M2 #210 (real hardware), M4 #212 (v0.9.0-rc), M5 #213 (v1.0.0). ROADMAP.md ladder already shipped v0.3.0-beta (#211); in-flight is v0.9.0-rc validation + signing.
- Dominant live risk: `e2e-gui.yml` red ~20 consecutive scheduled runs since 2026-09-01 (epic #399; snapshots #367/#364). Current mode A: GUI app never launches, no interactive session (autologon failure). This blocks the nightly auto-release channel by design.
- CI self-sabotage: `ci.yml` + `ci-tests.yml` share `cancel-in-progress: true` on `github.ref`, so merge trains on `main` cancel verdicts for already-merged commits (#363). Duplicate lint jobs on push+PR (#315).
- Security batch is concrete and small-scoped: workflow script injection (#373, #372, #282), unsigned/redirectable SHA256SUMS (#371, paired with #335 pin+sign), un-ACL'd `C:\wootc` (#370), dead credential envelopes (#281), BitLocker key on NTFS (#279).
- Recovery/idempotency cluster is half-landed: PRs #327/#338 cover #288/#331; parents #285 (recoverable installs), #287 (recovery state), #286 (transactional boot chain), #290 (boot repair), plus evidence issues #332 (first-boot json), #334 (steps catalogue), #333 (ESP refresh), #322 (Secure Boot CA preflight).
- Identity context: this is a planning turn only. No code, commits, or PR merges are performed under this plan until approval.

## Constraints And Non-goals

- Do not merge or close anything in this turn; this plan stops at approval.
- Do not launch 60–90 min E2E VM runs during implementation of units 1–4; use unit/BATS/CI evidence, and only schedule E2E where the Validation Plan names it.
- Maintainer-owned gates stay with the maintainer: signing spend decision (#229), winget `WINGET_TOKEN` secret, upstream blessings (#227), real-hardware runs (#216).
- Non-goals: libertix investigation (#308) beyond a time-boxed spike; full `run-e2e.sh` (4,373 lines, #383) or `deploy.sh` (3,621 lines, #380) refactors — seam-first only; STE 1728-findings clearance (#376) as a standalone campaign.
- WinUI phases B–E (#343–#346) are sequenced but not started here; phase A (`wootc.exe serve`, #348) is the assumed-done baseline.

## Key Decisions

- **Merge-ready PRs first (Unit 1), not the E2E fire.** All 7 PRs are green and mergeable; landing them shrinks the board by ~10 issues (they close #401/#357-part, #331, #288, #225, #223 and advance #241/#238) before any new code is written. Rejected alternative: fix E2E first — wrong order, because the merged PRs change the code E2E would be debugging.
- **CI integrity (Unit 2) before new product work.** #363 (cancel-in-progress on main) means any landing after Unit 1 is unverified by construction; fix the verdict pipeline before stacking more verdicts on it. Includes #315 dedup and coverage wiring (#368, #360, #402) so gates are real, not decorative (`codecov.yml` 45% gate currently unenforced).
- **Security batch (Unit 3) as one reviewable pass, ordered low→high blast radius.** Workflow `env:` fixes (#373, #372, #282) and renovate/permissions (#392) first (CI-only, zero product risk), then product trust root (#371+#335, #370, #281, #279). This unblocks the M4 signing story (#229/#230) which assumes a trustworthy artifact chain.
- **Recovery hardening (Unit 4) lands on top of merged #327/#338** rather than re-planning them: finish parents #285/#287/#286/#290 and evidence issues #332/#334/#333/#322 in that dependency order (idempotency → state → transactional boot → repair UI → attested evidence).
- **WinUI gets an evidence-carryover rule before any phase B–E work (#357).** M2 manual runs and matrix greens earned against the Wails exe must not be silently carried across the #346 deletion. Rule first (Unit 5), then phases B→C→D→E strictly in order.
- **Session-migration remainder (#1, #293–#296, #252–#259, #281-tied) is a closing wave, not a parallel track** — most of its beta-gate value already shipped via staged re-link (#347); the rest is ordered keyring → cookies/storage → orchestration → matrix.
- **Architecture findings (#383, #380, #297) and STE (#376) are explicitly last**: documented as tech-debt with seam tests, not rewrites, so they cannot stall the 1.0 gates.

## Recommended Approach

One sequential run of 8 units. Units 1–3 are merge/fix/verify loops with no new product surface. Unit 4 completes the recovery story. Units 5–7 close milestones and the WinUI cutover. Unit 8 sweeps leftovers and reconciles the roadmap. Each unit maps to the Validation Plan commands below; a unit is done only when its listed issues/PRs are merged/closed and its checks pass.

## Work Plan

### Unit 1 — Land the 7 green PRs (closes ~10 issues)

Merge in dependency order, verifying `gh pr view` checks still green at merge time:

1. #313 (BitLocker beta #223) + #317 (UAC identity #225, tracker #197 items) — policy/identity pair, lowest conflict risk.
2. #324 (#238 uninstall proof) + #325 (#241 fresh-machine verification) — M5 evidence enablement; both name hardware runs as still-open follow-ups, record them on #238/#241.
3. #327 (#288 fault-injection) + #338 (#331 recovery guard) — recovery cluster parents for Unit 4.
4. #401 (ROADMAP WinUI mention, part of #357) — docs-only, last to avoid conflicts.

Validation: `gh pr checks <n>` all green; `go test ./app/...` and `tests/run.sh` fast tier per merge.

### Unit 2 — CI and signal integrity (fixes the verdict pipeline)

- #363: scope `cancel-in-progress` to PRs only (or `github.run_id`-keyed groups on `main`); #315: dedup lint jobs.
- #399 epic driver: triage current Mode A (autologon, no interactive session) from `e2e-gui.yml` runs; file/confirm the focused fix issue; do not claim the epic — leave it open until a green nightly.
- #368 + #360: collect `-coverprofile` in `tests/run.sh`, upload to Codecov so the 45% gate bites; fix the subprocess-tested false-0% reporting. #402: add unit tests for `resolvedWindowsProfile` (`app/migration_linux.go:426`).
- #361: write the release-rollback runbook (`runbooks/` — currently missing entirely; `grep -ri rollback` hits only installer-side paths) documenting why delete-and-republish breaks pinned installers + winget.

Closes: #363, #315, #368, #360, #402, #361. Advances: #399 (stays open till green).

### Unit 3 — Security hardening batch

- CI-only first: #373 (`e2e-hosted.yml` `inputs.image` → `env:`), #372 + #282 (winget tag → `$env:TAG`; pin `wingetcreate.exe` or hash-check it), #392 (renovate preset + workflow permissions).
- Product trust root: #371 + #335 (pin release tag instead of `releases/latest` float; sign SHA256SUMS) — touches `app/deployer_url.go`, `app/deployer_windows.go`, `release.yml` (sign before SHA256SUMS, per M4 #212).
- Privilege boundary: #370 (ACL-restrict `C:\wootc` tree; `MkdirAll` perm bits are inert on Windows — needs explicit ACL, cf. `restrictFileACL` in `app/winexec_windows.go:30`).
- Credential hygiene: #281 (consume/remove staged `.enc` envelopes), #279 (BitLocker key off NTFS, seal to machine — beta-gate for #34).

Closes: #373, #372, #282, #392, #371, #335, #370, #281, #279.

### Unit 4 — Recovery and boot-chain evidence

Order (each depends on the last): #285 (interrupted installs recoverable/idempotent; #327 already landed) → #287 (interrupted-install recovery state) → #286 (transactional boot-chain changes with rollback) → #290 (user-facing boot repair action) → #331-verification (confirm merged #338 decision table against #332 first-boot `installed-linux-boot.json` cross-check) → #334 (single `payload/steps.tsv` catalogue, diffed in CI) → #333 (ESP signed-chain refresh after bootc upgrades) → #322 (Secure Boot 2011-vs-2023 CA preflight).

Closes: #285, #287, #286, #290, #331, #332, #334, #333, #322. (#288 already closed by Unit 1.)

### Unit 5 — WinUI cutover rule + phases (unblocks #357)

- First: write the evidence-carryover rule (#357) — which Wails-era greens (M2 runs, matrix cells, walkthrough imagery) survive the #346 deletion and which must be re-proven by the shell-driven E2E. Record it in ROADMAP.md (completing #401's TODO) and `docs/branding-and-distribution.md` if marks are affected.
- Then phases strictly in order: #343 (shell scaffold + windows-latest CI + Inno preview) → #344 (screens, E2E drive contract, one green shell-driven E2E) → #345 (artifacts switch, Wails kept as `wootc-legacy.exe`) → #346 (delete Wails/web/Linux dashboard/Playwright). #304 stays the parent epic #340.
- #219 (console flash) is verified against the shell, not the deleted Wails exe.

### Unit 6 — Milestone close-outs (M2 → M4 → M5)

- M2 #210: field-report template, maintainer + 2 hardware runs (#216), offline axis (#217), dakota decision (#218 → #209 demote-or-fix), winget accepted (#221). #302 (alpha cohort gate) is the entry criterion — confirm or explicitly waive.
- M4 #212: signing decision (#229, maintainer) → plumbing (#230, `release.yml` sign-before-SHA256SUMS, depends on Unit 3 trust root) → docs truth pass #233 → data-loss audit #234 (field corpus + destructive-path inventory) → soak ledger #235.
- M5 #213 + children #237/#238/#239/#240/#241/#242: destructive-path verification, uninstall proof on hardware (Unit 1 enabled collection), 30-day soak, full-matrix evidence at RC SHA, v1.0.0 cut.

### Unit 7 — Session migration closing wave

Order: #293 (safeStorage keyring adapter) → #254/#255 (Secret Service / KWallet) → #256 (Cookies SQLite) → #257 (LevelDB storage) → #294 (Chrome/Edge cookies) → #295 (Spotify) → #252/#253 (envelope unlock contract + Linux consumer) → #258 (orchestration + honest ledger) → #259 (transplant matrix) → #296 (validate + honest outcomes) → #1 (DPAPI rewrap post-beta verification — confirm or close as superseded by #347 staged re-link).

### Unit 8 — Leftovers, debt seams, roadmap rollover

- #209 dakota hang (if not closed in Unit 6): root-cause or demote to experimental per M2 rule.
- #196 offline bundle, #328 telemetry audit (adopt or decline per item), #197 remainder check (after #317 landed).
- #178 already cut from 1.0 by ROADMAP scope decision — close with pointer or move post-1.0.
- Architecture: #383/#380/#297 as documented seams + layout-coupled test decoupling only; #376 STE as batched doc fixes, not a campaign; #390 readiness audit reconciled; #24 dependency dashboard routine.
- Roadmap rollover: ROADMAP.md + `docs/status.md` matrix updated, M5.7 #242 cut notes.

## Validation Plan

- Per-merge (Units 1–4): `gh pr view <n> --json statusCheckRollup` green at merge time; `go test ./app/...`; `tests/run.sh` fast tier (bats + go); `shellcheck`/`yamllint` where touched (`ci.yml` lint job).
- Unit 2: `go test ./... -coverprofile=cov.out` + `go tool cover -func` shows `resolvedWindowsProfile` >0% and no package falsely 0%; Codecov upload present in workflow logs; `git log` on `main` shows no cancelled-then-merged runs for the unit's merges.
- Unit 3: `grep -rn '{{ inputs' .github/workflows/` shows no interpolation into `run:` blocks; `winget-publish.yml` reads tag from `env:`; release artifacts carry pinned tag + signature; new unit test asserts `C:\wootc` ACL and mirror-URL scheme/host validation.
- Unit 4: fault-injection BATS (`#288` suites from #327) + recovery decision-table tests pass; `payload/steps.tsv` diff job green in CI.
- Unit 5: at least one green shell-driven E2E before #345 flips artifacts (the #344 gate); Wails-era evidence explicitly marked carried vs re-proven per the #357 rule.
- Highest-risk validation: Unit 2's #399 Mode A (needs a live Windows VM autologon diagnosis; cannot be proven by unit tests) and Unit 6's hardware runs (#216/#238 — no CI substitute).

## Risks / Rollback

- Merging 7 PRs at once risks semantic conflicts despite green checks (recovery + uninstall + policy touch adjacent install paths). Mitigation: Unit 1's pairwise order + fast-tier re-run per merge; rollback is `git revert` of the single merge commit (all are separate branches).
- #363 fix changes CI concurrency for everyone; a mis-scoped group doubles CI spend. Mitigation: PR-scoped change first, observe one merge train before touching `main` push groups.
- #371/#335 change the artifact trust root; old installers pin old tags by design (see #361). Mitigation: never rewrite published tags; sign-before-SHA256SUMS only affects new releases.
- #370 ACL tightening can break existing installs where `C:\wootc` is already user-owned. Mitigation: migrate-and-restrict on first elevated run, with an explicit fallback error, not silent takeover.
- WinUI #346 deletion is irreversible per-release; the #357 rule is the guardrail — no deletion PR merges while carried-evidence items are still marked Wails-only.

## Open Questions

None. All sequencing unknowns were resolved from workspace facts above (issue/PR bodies, merge states, ROADMAP ladder, `docs/status.md` matrix). The maintainer-gated items (#229 spend, `WINGET_TOKEN`, hardware access for #216/#238) are recorded as owner tasks inside Units 6–8, not questions.
