# Runbook — rolling back a bad wootc release

Use this procedure for a published installer or boot chain that can harm users or fail to boot.
See [the release guide](../docs/RELEASING.md) for the normal release gate.
Record the bad tag, source SHA, artifact hashes, and the intended good tag before any change.
This procedure does not recall copies that users already hold.

## What a wootc release is, before you touch anything

A release contains the branded installers and shared boot assets.
For the current code, `SHA256SUMS` lists the asset hashes and `SHA256SUMS.sig` authenticates that exact manifest.
Each installer embeds the public key for its release.
`artifact-public-key.hex` lets reviewers check the signature; a downloaded key cannot replace the installer's embedded key.
Check the bad tag's source: older installers can have a different verification contract.

| Consumer | Where it points | What a rollback reaches |
|---|---|---|
| An exe already on a user's disk | `releases/download/<its own tag>/`, from `-X main.releaseTag=` | Changes to that tag's remote assets, when it needs a network fetch. Valid local inputs can still work. |
| A developer build, or anything unstamped | `releases/latest/download/` | The latest eligible release, when it needs a network fetch. Local inputs can still work. |
| Download links in README and the startup guide | `releases/latest` | The latest eligible full release. |
| winget (`TunaOS.wootc`) | A fixed `releases/download/<tag>/wootc.exe` | Changes to that URL or to the manifest in Microsoft's repository. |

The current engine verifies a local manifest and signature before it considers a network fetch.
It can reuse cached boot files whose hashes match that authenticated manifest.
The local cache and offline bundle can remain usable after you remove the remote assets.
A local manifest that is invalid fails without a network fallback.

A failed verification stops the boot-asset download stage.
It does not prove that the installer made no changes: directory and disk preparation occur before that stage.
Preserve the user's state and use the repair or uninstall procedure for that exact build.

## Step 0 — decide what you are containing

Answer these questions in the incident record:

1. Can new users reach the bad build through `latest`, Releases, or winget?
2. Can it lose data or prevent a boot, or does it fail with Windows intact?
3. Is the defect in the installer, its remote boot assets, or cached inputs?
4. Is a full release available that passed its tests, with compatible assets and a valid signature?

Choose a lever for each affected consumer. Do not treat a metadata change as a recall.

## Step 1 — stop new users landing on it (always do this)

A prerelease cannot be the latest full release.
Mark the bad release as a prerelease:

```sh
gh release edit <bad-tag> --repo tuna-os/wootc --prerelease
```

Observe the result and explicitly select the full release that passed its tests:

```sh
gh api repos/tuna-os/wootc/releases/latest --jq '.tag_name, .prerelease'
gh release edit <last-good-tag> --repo tuna-os/wootc --latest
gh api repos/tuna-os/wootc/releases/latest --jq '.tag_name, .prerelease'
```

If no full release passed its tests, `latest` cannot provide a good fallback.
Keep the bad build out of `latest` and remove download recommendations until a replacement passes its gates.
Pinned copies and caches do not follow this metadata change.
See [GitHub's release API](https://docs.github.com/en/rest/releases/releases) and [CLI command](https://cli.github.com/manual/gh_release_edit).

## Step 2 — stop the pipeline re-publishing the same commit

`e2e-gui.yml` runs at `cron: '0 7 * * *'`.
A successful scheduled GUI run triggers the auto channel in `release.yml`.
It publishes `auto-vYYYYMMDD-<sha>` from the tested SHA as a prerelease.
These releases do not take `latest`, but users can find them on the Releases page.

Revert the faulty code on `main`, then test that tree.
If that cannot happen at once, disable the GUI workflow while the correction proceeds:

```sh
gh workflow disable e2e-gui.yml --repo tuna-os/wootc
gh api repos/tuna-os/wootc/actions/workflows/e2e-gui.yml --jq .state
```

Inspect active runs and release jobs that have not finished. A disabled schedule does not cancel a release job already in progress.
Record any cancellation against its exact run ID; preserve its evidence.
Track and verify the return to service after the correction:

```sh
gh workflow enable e2e-gui.yml --repo tuna-os/wootc
gh api repos/tuna-os/wootc/actions/workflows/e2e-gui.yml --jq .state
```

## Step 3 — only if the build is dangerous: withdraw the assets

Preserve private copies of the release metadata, assets, hashes, and gate evidence before removal.
For a dangerous build, withdraw the remote inputs that an uncached installer needs:

```sh
# withdraw one asset
gh release delete-asset <bad-tag> <asset> --repo tuna-os/wootc --yes
# withdraw everything, keeping the git tag
gh release delete <bad-tag> --repo tuna-os/wootc --yes
```

Keep the Git tag and source history.
Verify the HTTP response for each affected URL after the change.
A current installer with no cache refuses unavailable or invalid signed metadata.
A valid local manifest, signature, and matching boot files can still let it proceed.
Do not report asset removal as a stop for every downloaded copy.

A winget URL for a removed `wootc.exe` returns an error; it does not redirect to an earlier version.
Plan the winget response before that removal.

Do not replace boot assets under an old tag with a different release's files and signature.
The embedded key, manifest, asset hashes, installer compatibility, and VM proof must all agree.
The current release workflow creates a key for each release and removes its private seed after use.
A key that you generate now cannot sign a replacement that the old installer accepts.
If the original key is unavailable, publish a new release through its gates.

Checksums alone do not authenticate the files.
Copies of the old files in a valid cache do not follow even an authorized replacement.

## Step 4 — winget

`winget-publish.yml` submits manifests; it has no withdrawal action.
Inspect the exact published version in `microsoft/winget-pkgs` and its `InstallerUrl`.
Check the existing submission run for an actual PR and its merge status.
Without `WINGET_TOKEN`, the workflow only renders manifests and exits successfully.

Publish a new full release that passed its tests to move normal installs forward.
If the bad version must disappear, submit a PR that removes that exact version's manifests from Microsoft's repository.
An open PR is not proof that the package source has changed.

After its merge, refresh the winget source on a clean machine and observe the offered version and resolved URL.
Check explicit requests for the bad version too.
Do not promise a fixed moderation delay.
See [the official repository guidance](https://github.com/microsoft/winget-pkgs/blob/master/doc/README.md).

Only the generic `TunaOS.wootc` manifest is part of this workflow; brands need their own distribution review.

## Step 5 — forward-fix

Publish the replacement through the normal tests and a fresh gate in a Windows VM.
Use the replacement's exact installer, signature, boot files, and source SHA.
`skip_e2e` bypasses the VM gate and adds a warning to the release notes.
If you use that bypass, record the unproven runtime behavior in the incident.
A release does not automatically update copies on users' disks.

## Verification checklist

Keep each result with its timestamp, source, tag, and artifact identity:

- [ ] The latest-release API returns the intended tag for a full release, or records that no eligible fallback exists.
- [ ] The intended good tag's `SHA256SUMS` and `SHA256SUMS.sig` download and verify against its trusted key.
- [ ] Required boot files and branded installers match the authenticated hashes and their recorded gate evidence.
- [ ] The bad tag has the intended metadata and asset availability; verify actual URLs, not only command status.
- [ ] The faulty code is absent from `main`, or the workflow is disabled with a tracked return-to-service action.
- [ ] Active GUI and release runs cannot republish the faulty source; retain exact run observations.
- [ ] Any winget removal or replacement has merged, and a fresh source query shows the intended version and URL.
- [ ] The incident records limits for pinned installers, caches, offline bundles, and users who already installed.

## What this rollback cannot do

The installer has no release-revocation callback.
You cannot notify, recall, or upgrade a copy on a user's disk through the release page.
Asset removal can stop a new network fetch. Valid local inputs can still work, and an installation remains in place.
Give affected users the version-specific repair instructions and a tested replacement.
Do not present a signature or checksum as proof that the release is safe to boot.
