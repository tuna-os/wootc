# Project review — 2026-09-26

I reviewed `main` at `68080be`, the status matrix, the roadmap, 79 open issues,
and PR #325. I also read recent CI and GUI E2E logs. This is a focused review,
not a full audit. I kept the local edits in `ROADMAP.md` and `.agents/`.

## Release gates

1. **GUI startup fails.** The latest
   [GUI run](https://github.com/tuna-os/wootc/actions/runs/36240171646)
   reports `wootc.exe did not start within 60 s — e2e-drive-state.json never appeared`.
   The two prior runs also failed. Fix
   [#399](https://github.com/tuna-os/wootc/issues/399) first. The log alone does
   not show whether autologon, the task, or the app caused the failure.
   Inspect the session, task result, and app logs before a change to the deployer.
   The fix needs a hosted GUI run at the same SHA.

2. **CI loses results.** GitHub cancelled the runs for `2acbd73` when a newer
   commit arrived. Both CI workflows put pushes to `main` in one group.
   The patch for [#363](https://github.com/tuna-os/wootc/issues/363) gives each
   push or dispatch its own group. Only updates to a PR can cancel prior runs.
   A shared group can also lose queued runs. See
   [GitHub's concurrency rules](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

3. **Release trust needs more work.** The input and token defects in
   [#373](https://github.com/tuna-os/wootc/issues/373) and
   [#282](https://github.com/tuna-os/wootc/issues/282) were present.
   The patch passes image, fault, and tag values through environment variables.
   It checks tag syntax and limits write tokens to jobs that need them.
   It removes the duplicate preset from
   [#392](https://github.com/tuna-os/wootc/issues/392).
   The files `ci.yml` and `ste.yml` already had read-only defaults.
   The unverified `wingetcreate` download in
   [#372](https://github.com/tuna-os/wootc/issues/372) still needs a fix.
   The trust defects in [#371](https://github.com/tuna-os/wootc/issues/371) and
   [#370](https://github.com/tuna-os/wootc/issues/370) also remain open.

## PR #325

[Fresh-machine trust verification](https://github.com/tuna-os/wootc/pull/325)
at `bce172d9781ffb488db8cd98c996aedadd6bdd37` has green CI. Each check helps
collect evidence. I found two gaps in that revision:

- **P2: partial identity can pass.** `Test-BrandIdentity` checks the product name
  and searches three fields for `wootc`. It accepts an empty company, description,
  or version. The input `@{ ProductName = 'Bazzite Installer' }` can pass.
  Check that all four fields exist. Compare the version to the chosen release.
  Add a test for each absent field.
- **P2: latest can pass with an old package.** Without `-Tag`, downloads use
  `releases/latest`. The winget check gets no expected version and accepts any
  version it finds. Resolve latest once to a tag. Use that tag for each download
  and each version check.

This review is based on the source. It does not prove the result on Windows.
Keep [#241](https://github.com/tuna-os/wootc/issues/241) open until signed files,
complete metadata, and both reports from fresh machines exist.

## Work order

1. Merge the workflow fixes after CI, then fix the GUI gate (#399).
2. Complete release trust: verified tools, signed artifacts, and directory ACLs
   (#372, #371, #370, #229, #230).
3. Prove recovery, offline installs, uninstall, and the file bridge on the matrix
   and on hardware. Close issues only when their evidence exists.
4. Define which evidence survives the WinUI change (#357) before the release
   switch (#345). Prove the new shell with its own GUI run.

The goal is a Windows-to-Linux journey that keeps the user's files intact.
Prove that journey and recovery before more features.

## Local checks

- Seven tests for the workflows pass. They fail with deliberate defects:
  shared CI groups, broad write tokens, script injection, and broken checks for tags.
  The tests run the actual Bash block with valid and hostile tags.
- The workflows pass `actionlint -shellcheck=`. Full actionlint reports five
  style/info findings that also exist on the baseline. `git diff --check` passes.
- I ran all 584 Bats tests. One guard expected the unsafe tag assignment.
  I changed that guard to check the safe environment variable.
  All 18 tests in that suite then passed. Python and app Go tests pass.
- The fast tier fails in the unchanged fisherman submodule.
  `internal/slurp.TestExtractData_FullFlow` gets a zero scratch budget and
  reports `Found = false`. Other Go packages pass. The submodule has no edits.
  This initial run had no `pwsh`, so it skipped PowerShell tests.
- This initial review did not launch VM tests, merge PRs, or close issues.
  The patch needs hosted CI and PowerShell checks before merge.
