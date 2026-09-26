# Project review — 2026-09-26

Reviewed local `main` at `68080be`, the status matrix and roadmap, the list of
79 open issues, the one open PR (#325), and recent CI and GUI E2E logs.
This is a triage and focused code review, not a complete audit of every issue.
Existing local edits to `ROADMAP.md` and `.agents/` were preserved.

## Findings that affect the next release

1. **The release gate is still red before the installer starts.** The latest
   [GUI run](https://github.com/tuna-os/wootc/actions/runs/36240171646)
   reports `wootc.exe did not start within 60 s — e2e-drive-state.json never appeared`.
   The preceding two scheduled runs also failed. This supports prioritizing
   [#399](https://github.com/tuna-os/wootc/issues/399); it does not establish
   whether autologon, task launch, or the app caused this particular failure.
   Capture the interactive session, scheduled-task result, and app exit/logs
   before changing deployer code. Closure needs a hosted GUI run at the fixed SHA.

2. **Merges erase earlier CI verdicts.** The runs for `2acbd73` were cancelled
   while the newer `68080be` runs passed. Both CI workflows grouped main pushes
   together with cancellation enabled. The local patch addresses
   [#363](https://github.com/tuna-os/wootc/issues/363): only PR updates share a
   cancellation group; each push/dispatch run gets its own group. Merely turning
   off cancellation would still allow pending runs to replace each other.
   See [GitHub's concurrency semantics](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

3. **Release trust has work beyond signing.** The workflow input and token
   issues in [#373](https://github.com/tuna-os/wootc/issues/373) and
   [#282](https://github.com/tuna-os/wootc/issues/282) were present. The patch
   moves image, fault, and release-tag values into environment variables,
   validates release tags, and scopes write tokens to publishing/retry jobs.
   It also removes the duplicate Renovate preset from
   [#392](https://github.com/tuna-os/wootc/issues/392). Contrary to that issue's
   older snapshot, `ci.yml` and `ste.yml` already declared read-only defaults.
   The unverified `wingetcreate` download in
   [#372](https://github.com/tuna-os/wootc/issues/372) remains open, as do the
   artifact-authenticity and installer-directory issues
   [#371](https://github.com/tuna-os/wootc/issues/371) and
   [#370](https://github.com/tuna-os/wootc/issues/370).

## Open PR #325

[Fresh-machine trust verification](https://github.com/tuna-os/wootc/pull/325)
at `bce172d9781ffb488db8cd98c996aedadd6bdd37` has passing reported checks and
adds useful evidence collection. Two correctness
gaps should be addressed before treating its checklist as a release gate:

- **P2: incomplete identity can pass.** `Test-BrandIdentity` checks the expected
  product name and searches three fields for `wootc`, but does not require a
  nonempty description, company, or version. A hashtable containing only
  `ProductName = 'Bazzite Installer'` passes with that expected product. Require
  the promised fields and compare version to the selected release; add negative
  tests for each missing field. Otherwise a partial VERSIONINFO fix can look
  complete in the checklist.
- **P2: default latest-release checks do not compare versions.** Without `-Tag`,
  downloads use `releases/latest`, but `Test-WingetPackage` gets an empty expected
  version. Its existing test explicitly permits any reported winget version in
  that case. An old winget package can pass beside a newer downloaded release.
  Resolve latest once to a concrete tag and use it for downloads and grading.

These are source-review findings; the PR's PowerShell was not executed locally.
Keep [#241](https://github.com/tuna-os/wootc/issues/241) open until signing,
metadata, and both fresh-machine reports exist. Green CI for this PR is evidence
for tooling, not evidence that users receive trusted binaries.

## Recommended order

1. Land the workflow safeguards after CI, then restore the GUI E2E gate (#399).
2. Finish release trust: verified tooling, artifact authenticity, directory ACLs,
   signing choice and integration (#372, #371, #370, #229, #230).
3. Verify recovery, offline installation, uninstall, and the file bridge through
   the hosted matrix and the hardware reports. Reconcile stale issue checklists
   against that evidence rather than closing parents because code was merged.
4. Set the WinUI evidence-carryover rule (#357) before release cutover (#345).
   A new shell needs its own successful GUI journey; Wails screenshots and drive
   tests cannot prove it. Keep broader migration features behind these gates.

The project's differentiator is a reversible Windows-to-Linux journey with the
user's files intact. The next milestone should prove that journey reliably and
make failures recoverable before increasing the supported feature set.

## Local validation of this patch

- Seven workflow regression tests pass. Five deliberate mutations are rejected:
  shared main concurrency, broad write permissions, script interpolation,
  disabled release-tag validation, and inverted winget validation. The release
  tests execute the actual Bash block with valid and hostile tag values.
- All changed workflow definitions pass `actionlint -shellcheck=`. Full
  actionlint reports the same five pre-existing ShellCheck style/info findings
  in `release.yml` as the unchanged baseline. `git diff --check` passes.
- Ran all 584 Bats tests. The only failure was an assertion requiring the old
  unsafe release-tag assignment. Updated it to require the environment binding;
  all 18 tests in that suite then passed. Python suites and the app Go tests pass.
- The full fast tier remains red in the unchanged, pinned fisherman submodule:
  `internal/slurp.TestExtractData_FullFlow` reports a zero scratch budget and
  `Found = false`. Other reported Go packages pass. The submodule working tree
  is clean. PowerShell tests were skipped because `pwsh` is unavailable.
- No hosted workflows or VM tests were launched. No PR was merged and no issue
  was closed. The patch is local and still needs hosted CI, including Windows
  PowerShell validation, before landing.
