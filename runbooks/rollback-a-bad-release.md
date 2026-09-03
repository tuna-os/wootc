# Runbook — rolling back a bad wootc release

Use this when a published release must stop reaching users: a broken or
dangerous installer, boot artifacts that fail to boot on real firmware, a
shim that no longer chains to a CA the user's machine holds, or any build
that puts a stranger's only computer at risk.

Cutting a release is documented in [docs/RELEASING.md](../docs/RELEASING.md).
This is the other direction.

## What a wootc release is, before you touch anything

A release is not one file. Every release carries the full artifact set:
one `*.exe` per blessed brand, the shared boot artifacts
(`deployer-vmlinuz`, `deployer-initramfs.img`, `shimx64.efi`, `grubx64.efi`,
`mmx64.efi`, and `wubildr.efi` when its build succeeded), and a `SHA256SUMS`
covering all of them.

Three consumers point at those assets, and each reacts differently to a
rollback:

| Consumer | Where it points | What a rollback reaches |
|---|---|---|
| An exe already on a user's disk | `releases/download/<its own tag>/` — pinned at build time (`-X main.releaseTag=`, `app/deployer_url.go`) | Only changes to **that tag's** assets. The exe never learns about a newer or older release. |
| A developer build, or anything unstamped | `releases/latest/download/` | Whichever release is currently marked latest. |
| The download links in `README.md` and `docs/getting-started.md` | `releases/latest` | Whichever release is currently marked latest. |
| winget (`TunaOS.wootc`) | the manifest's `InstallerUrl`, a fixed `releases/download/<tag>/wootc.exe` | Nothing in this repository. See "winget" below. |

The pinning is deliberate — an installer and its boot chain ship and are
E2E-gated together — but it is also the reason a rollback has a smaller
blast radius than people expect. **Un-publishing a release does not recall
the exes already downloaded from it.** Only editing that tag's assets does.

The installer's boot-artifact verification is fail-closed: a missing
`SHA256SUMS`, a missing entry, or a hash mismatch aborts the install with
`cannot verify boot artifacts` and nothing is written. That is the property
every step below either preserves or deliberately uses.

## Step 0 — decide what you are containing

Answer before pulling a lever, because the answer picks the lever:

1. **Is the bad build reachable by new users?** (Is it marked latest? Is it
   in winget?)
2. **Is the bad build dangerous to someone who already has the exe** — data
   loss, an unbootable machine — or merely broken (fails, leaves Windows
   intact)?
3. **Is the fault in the exe, or in the boot artifacts it downloads?**

A wootc install that refuses to proceed is an acceptable outcome; a wootc
install that proceeds into a broken boot is not. Prefer levers that make the
bad path refuse.

## Step 1 — stop new users landing on it (always do this)

Marking the bad release as a pre-release moves GitHub's `latest` back to the
previous full release, which fixes the README/getting-started download links
and every unstamped build, while leaving the assets downloadable so exes
pinned to that tag still verify and install rather than dying mid-run:

```sh
gh release edit <bad-tag> --repo tuna-os/wootc --prerelease
```

Then confirm — do not assume — which release `latest` now resolves to, and
pin it explicitly if it is not the one you want:

```sh
gh api repos/tuna-os/wootc/releases/latest --jq '.tag_name, .prerelease'
gh release edit <last-good-tag> --repo tuna-os/wootc --latest
```

This is the default lever. It is reversible in one command.

## Step 2 — stop the pipeline re-publishing the same commit

The auto channel republishes on its own. `e2e-gui.yml` runs on a schedule
(`cron: '0 7 * * *'`), and a green run triggers `release.yml`'s
`workflow_run` channel, which cuts `auto-vYYYYMMDD-<sha>` from the exact SHA
the nightly proved. If the bad code is on `main`, a new pre-release carrying
it appears every night and sits at the top of the Releases page.

So containment is not complete until one of these is true:

- the offending commit is reverted on `main` (preferred — the nightly then
  proves the reverted tree), or
- the schedule is paused: disable `E2E GUI-driven (publish timelapse)` for
  the duration (`gh workflow disable e2e-gui.yml --repo tuna-os/wootc`), and
  re-enable it the moment the revert lands.

Auto releases are pre-releases, so they never take `latest` from you — but
they are still the newest thing a user browsing Releases sees.

## Step 3 — only if the build is dangerous: withdraw the assets

Deleting assets (or the whole release) is the only action that reaches an
exe already on a user's disk. It is also the most destructive one, so read
both consequences first:

- Every exe pinned to that tag fails at
  `cannot verify boot artifacts: SHA256SUMS manifest unavailable` and
  installs nothing. For a dangerous build this is the point.
- If that tag's `wootc.exe` is referenced by a published winget manifest,
  the manifest's `InstallerUrl` starts returning 404 and
  `winget install TunaOS.wootc` breaks outright. winget does **not** fall
  back to the previous version.

If the fault is in the boot artifacts and *not* in the exe, there is a
narrower option: replace that tag's boot artifacts with the known-good ones
**and** upload the matching regenerated `SHA256SUMS`, so pinned exes fetch a
chain that verifies. Never replace artifacts without republishing
`SHA256SUMS` in the same edit — a half-updated tag is a fail-closed abort
for every user on it.

```sh
# withdraw one asset
gh release delete-asset <bad-tag> <asset> --repo tuna-os/wootc --yes
# withdraw everything, keeping the git tag
gh release delete <bad-tag> --repo tuna-os/wootc --yes
```

Keep the git tag either way: deleting it rewrites what
`auto-*`/`v*` history means and buys nothing.

## Step 4 — winget

`winget-publish.yml` is one-directional. It submits `TunaOS.wootc` to
`microsoft/winget-pkgs` for full releases and has no path to withdraw one.
A published bad version therefore keeps installing until a human acts, and
that action lives in Microsoft's repository, not this one:

- **Preferred:** publish a superseding full release. `release.yml` dispatches
  `winget-publish.yml` for it automatically, and winget users move forward.
- **If the bad version must be pulled:** open a version-removal PR against
  `microsoft/winget-pkgs` for the exact version, and expect moderation
  latency measured in days, not minutes.
- Submission needs the `WINGET_TOKEN` secret. Without it the workflow prints
  the manifests and exits green — so a green winget run is not proof that
  anything was submitted. Check the run log before assuming a version is
  live.

Branded installers are deliberately not submitted to winget, so a rollback
only ever concerns `TunaOS.wootc`.

## Step 5 — forward-fix

Rolling back buys time; it is not the fix. Cut the replacement through the
normal gate — tag, tests, real-Windows-VM E2E, publish. `skip_e2e` exists for
the case where the gate itself is what is broken; it stamps its own warning
into the release notes, and using it means the replacement is unproven
against a real VM. Say so in the incident notes if you use it.

## Verification checklist

Do not close the incident until every line is checked, by observation:

- [ ] `gh api repos/tuna-os/wootc/releases/latest --jq .tag_name` prints the
      intended good tag.
- [ ] `https://github.com/tuna-os/wootc/releases/latest/download/SHA256SUMS`
      downloads, and lists the shared boot artifacts.
- [ ] The bad tag's release page shows the state you intended (pre-release,
      or assets withdrawn) — check the page, not the command's exit code.
- [ ] `main` no longer contains the offending commit, **or** `e2e-gui.yml`
      is disabled and an issue tracks re-enabling it.
- [ ] If winget carried the bad version: the removal or supersede PR is
      open, linked from the incident.
- [ ] A dated note in the incident record says which lever was pulled and
      what it did not reach — specifically, that exes pinned to the bad tag
      are unaffected unless step 3 was used.

## What this rollback cannot do

wootc has no callback, no update ping, and no telemetry. There is no way to
learn how many users hold an exe from the bad tag, and no way to tell them.
The pinned-artifact design means their installer will keep behaving exactly
as it did the day they downloaded it. Withdrawing that tag's assets (step 3)
is the only mechanism that changes their outcome, and it changes it to
"refuses to install", never to "installs the good build".
