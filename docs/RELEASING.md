# Releasing wootc — the green-gated ladder

wootc writes Linux onto a stranger's only computer. Its North Star is that a nervous Windows user must not lose data.
**The app offers only scenarios with green evidence in the E2E matrix.**
It hides other scenarios until they pass. Each matrix cell opens its feature after it passes.
A whole tier must pass before its channel can advance.

## The single source of truth

The [build/test matrix](status.md#buildtest-matrix) is authoritative. A
combination earns *green* only after hosted E2E (`e2e-matrix.yml` /
`e2e-gui.yml`) passes the full cycle.
The cycle is Windows seed → deploy → Phase-2 bridge → Phase-3 native disk → seeded file on the native disk.

Two places consume that status, and they must agree:

- **`app/data/images.json`** — each image carries `"status": "green" |
  "experimental"`. Alpha offers only `green` images.
- **`app/app.go` `GetSupportPolicy()`** — per-channel gate for the *scenario*
  axes (BitLocker/FDE, custom OCI refs, encryption). The frontend reads it to
  gate the UI; `StartInstall` enforces it as the authoritative backstop.

When a matrix cell passes, update its `status` and the applicable policy flag.
Include those changes in the PR that records the run that passed. Never open a gate before its evidence.

## Channels

The active channel comes from `$WOOTC_CHANNEL`, else `C:\wootc\channel.txt`,
else the built-in default (`alpha`).

| Channel | Bar to enter | Offers |
|---|---|---|
| **alpha** | one image green end-to-end (incl. GUI-driven) | green images only; encryption off; no BitLocker; no custom refs |
| **beta** | the **full matrix** green | all images; custom refs; still gates any axis whose issue is open |
| **stable** | full matrix green + a soak period with no data-safety regressions | everything |

Alpha deliberately refuses more than it allows. A blocked user with intact
Windows is a good outcome; a walked-into-red user with a broken boot is not.

## Alpha (now)

- **Image:** `ghcr.io/projectbluefin/bluefin:stable`, the same grub2 stack as the discontinued `bluefin:lts`, on which the full cycle passed, including a run through the GUI.
- **Encryption:** off only. `tpm2-luks` (Phase-2 regen, [#33](https://github.com/tuna-os/wootc/issues/33))
  and BitLocker FDE ([#34](https://github.com/tuna-os/wootc/issues/34)) remain unavailable in alpha.
  The app detects BitLocker and tells the user about that limit. It refuses to continue into a known failure.
- **Root filesystem:** ext4 (sealed default). The app refuses btrfs
  ([#35](https://github.com/tuna-os/wootc/issues/35)).
- **No custom OCI refs** — only the offered, tested image.

## The unlock path to beta

Each item opens a gate when its matrix row passes:

- [x] yellowfin / bonito / marlin / flounder full three-phase → `status: green`
- [x] composefs-native (dakota) Phase-2/3
- [x] Windows 10 + Home/Enterprise/LTSC editions
- [x] BitLocker FDE path (#34) → `BitLockerSupported: true`
- [ ] tpm2-luks root (#33) → offer encryption
- [ ] btrfs sealed Phase-2 (#35) → offer btrfs
- [x] custom OCI refs (once the deploy path is family-agnostic green) → `CustomImageAllowed: true`

When the **whole matrix** passes, `beta` becomes the default channel.
The catalog then offers all images and lets users select custom references.
The gates for each axis open as their issues close.

## Native shell release gates

The [roadmap](../ROADMAP.md#native-shell-sequence-and-evidence-357) puts the
WinUI default change before 1.0. Phase B packages remain preview assets.
Phase C must prove the native consumer journey, the VM journey, and full cycles.
Phase D changes the default only after those gates pass. Keep the legacy
artifact for one release. Phase E follows a clean native release and the docs audit.

A release cannot use old Wails passes as native UI or setup proof. Carry only
component evidence whose engine code and contract did not change. Re-run the
native hardware journeys, branded walks, accessibility checks, and matrix cells.
A new artifact needs fresh signature checks and offline tests of its package.

The 1.0 soak needs phase D and all RC prerequisites complete, then a recorded
start date. Each eligible row must name the native shell, source SHA, artifact
identity, verdict, and GUI proof run on main. Exclude Wails rows.
A shell or transport change needs fresh proof; its earlier streak cannot carry.
Use the [run ledger](soak.md) for #235. Do not claim the #239 streak from a release
list alone or from dates before these gates pass.

## Cutting a release

Releases are **E2E-gated**. The tagged gate uses Windows 11, Bluefin LTS,
BitLocker off, GUI install, and `phase3: true` on a hosted runner.
It ends in graduated Linux and checks this run's file from Windows Documents.
That final boot does not prove a Windows return after graduation.

Automatic pre-releases use the successful GUI run on main and build its exact
source SHA. Their proof covers the stages selected by that run.
The `skip_e2e` input can waive the gate for an emergency dispatch.
The release notes disclose that waiver.

```
git tag v0.1.0-alpha.1 && git push origin v0.1.0-alpha.1
# → tests → E2E gate (real Windows VM, bluefin:stable, GUI-driven) → build + publish
```

Every release ships the **full artifact set** from `release.yml`.
It includes one installer per brand directory: `wootc.exe`,
`TunaOS-Installer.exe`, `Bluefin-Installer.exe`, `Bazzite-Installer.exe`, and
`Aurora-Installer.exe`. These use Wails with Go and a web UI. Their Windows interface needs the WebView2 runtime.

The shared boot artifacts are `deployer-vmlinuz`, `deployer-initramfs.img`,
`shimx64.efi`, `grubx64.efi`, and `mmx64.efi`.
The set also includes `wubildr.efi` when its build succeeds.
`SHA256SUMS` lists hashes for all these files. `skip_e2e` exists for emergencies and
documents itself in the release notes.

## Full-matrix evidence at the RC SHA (v1.0 criterion 3)

The release notes for v1.0.0 cite one run set at the exact release SHA.
A green from an earlier commit does not count. [#240] records this set.

1. Dispatch `e2e-matrix.yml` at the RC SHA with `tier=full` two times.
   Set `gui_install` off for script mode, and on for GUI mode.
   The run title then shows the tier and the mode, for example
   `E2E matrix (full, gui)`.
2. If a cell fails, read its flake notice. The harness writes this notice only
   for a known infra signature. Re-dispatch that cell with `grep=<cell>`, or
   re-run the failed job. Do not re-run a red cell that has no flake notice.
   Diagnose it, because it is a real failure.
3. Grade the run set and paste the output into [#240] and the release notes:

```
tools/release/matrix-evidence.py check --sha <rc-sha> \
    --run <script-run> --run <gui-run> [--run <retry> ...] \
    --snapshot matrix-evidence.json
```

The matrix plan runs `tests/e2e/validate-matrix.py` before it fans out. This
keeps `app/data/images.json` as an evidence output rather than a source for
case generation, while failing early if a green catalog image lacks ordinary
Windows 10 or 11 Pro coverage. Axis-specific rows (BitLocker, filesystem,
offline, recovery, firmware-db, and Phase 3) do not satisfy that primary-image
gate.
The tool reads `tests/e2e/matrix.tsv` at the RC SHA and expects each
full-tier cell that the hosted plan runs. GUI mode expects only the cells that
the `gui_install` guard drives. The BitLocker, `filesystem=`, and offline cells
use script mode only. The tool marks a cell green only when all of these are true:

- The last try of the cell has a passed job.
- The job log shows the pass banner of `run-e2e.sh`. The harness prints this
  banner only after it finds an empty failure ledger.
- Each earlier red try of that cell has a flake notice.

The tool exits with a non-zero code if a cell is missing, red, or has a red
with no explanation. It also exits with a non-zero code if a run is at a
different SHA, or if the matrix has no `bitlocker=on` or `offline=on` cell.
The phase3 cells are too large for the disks of hosted runners. The record
names them as not in the hosted matrix.
Keep the `--snapshot` file with the evidence, because job logs expire after
90 days. Use `tools/release/matrix-evidence.py grade` to grade the file again offline.

## Fresh-machine verification (v1.0 criterion 4)

The checks above run on machines that already know wootc. Trust is a
different problem. It is what the Windows of a stranger says about our files
*before* anything runs. This includes SmartScreen, the UAC publisher line,
the properties dialog, and whether winget knows the package. No E2E run can see this,
because the harness never asks Windows about the binary.

[#241] does this check on two machines that have never had wootc: a clean
Windows 11 VM and a real machine.

```powershell
# On each machine, from a checkout (needs the brand configs):
.\tests\field\verify-fresh-machine.ps1 -Tag v1.0.0 -Out C:\fresh-proof
```

The script grades all four criteria from evidence and writes `checklist.md`.
It exits with a non-zero code if a box fails:

| Box | How it is decided |
|---|---|
| winget serves the release | `winget show TunaOS.wootc` resolves **and** reports the version under test — a manifest that resolves to last month's alpha is a quieter failure than no package at all |
| winget installs the release | `winget install TunaOS.wootc` exits 0, and the exe it puts on disk has the `SHA256SUMS` hash of this release's `wootc.exe`. A winget success that installs a different file is a fail |
| each asset matches `SHA256SUMS` | `Get-FileHash` against the published manifest; an asset the manifest does not list fails rather than being skipped |
| each exe is Authenticode-signed | `Get-AuthenticodeSignature` must be `Valid` *and* name a signer. `HashMismatch` is called out separately — that is a tampered download, not an unsigned one |
| each branded exe shows its own identity | the exe's VERSIONINFO `ProductName`/`FileDescription`/`CompanyName` match that brand and contain no "wootc" |

A person must attach three screenshots, because a script cannot make them:
- The UAC prompt.
- The **Properties ▸ Details** tab of the exe.
- The SmartScreen interstitial, or a note that it did not show.

### Signatures and file identity

**No release has a signature yet.** [#229] is the choice and purchase of a
signature method. This is a spend decision for the maintainer. Until a
credential exists, each signature box is ✘. SmartScreen shows the wall for
unknown apps, and UAC shows "unknown publisher".

The pipeline side ([#230]) is ready for any credential that #229 selects.
The release step `Authenticode-sign the installers` runs
`packaging/sign-exes.sh` after the build of the exes and before the
step that writes `SHA256SUMS`. Authenticode changes the bytes of the file, so the
checksums must come after the signature. `tests/unit/release-pipeline.bats`
keeps this order.

The script uses [jsign], which supports the Azure `TRUSTEDSIGNING` service, cloud HSM keys
for EV certificates, and PKCS12 files. Repository variables select the
credential:

| Name | Kind | Value |
|------|------|-------|
| `WOOTC_SIGN_STORETYPE` | variable | jsign `--storetype`, for example `TRUSTEDSIGNING`. Empty means that signing is not configured |
| `WOOTC_SIGN_KEYSTORE` | variable | jsign `--keystore`: the endpoint, the vault, or the file |
| `WOOTC_SIGN_ALIAS` | variable | jsign `--alias`: the key, or `account/profile` for Trusted Signing |
| `WOOTC_SIGN_PUBLISHER` | variable | the CN that the signer certificate must show |
| `WOOTC_SIGN_TSAURL` | variable | optional RFC 3161 timestamp server |
| `WOOTC_SIGN_STOREPASS` | secret | the token or password. jsign reads it from the environment. Not used with the Azure OIDC login |
| `WOOTC_SIGN_CA_PEM` | variable | optional PEM roots for the check of the signature and the timestamp |
| `WOOTC_SIGN_CERTCHAIN_PEM` | variable | optional PEM chain for jsign `--certfile`. Some HSM store types need it |
| `AZURE_CLIENT_ID` | variable | the Entra application (client) ID for the OIDC login. Only with `TRUSTEDSIGNING` |
| `AZURE_TENANT_ID` | variable | the Entra tenant (directory) ID |
| `AZURE_SUBSCRIPTION_ID` | variable | the subscription of the Trusted Signing account |

The check uses the Ubuntu CA bundle. That bundle has TLS roots only.
The Azure `TRUSTEDSIGNING` certificates chain to a Microsoft root that is not in
the bundle (`Microsoft Identity Verification Root Certificate Authority 2020`).
The timestamp service `timestamp.acs.microsoft.com` chains to the same root.

For `TRUSTEDSIGNING`, the script adds this root from the repository file
`packaging/authenticode-roots/microsoft-identity-verification-root-2020.pem`.
A file in the repository gets a review when it changes, and a variable does not.
`tests/unit/release-pipeline.bats` pins its SHA-256 fingerprint. Use
`WOOTC_SIGN_CA_PEM` only for other credentials.

For `TRUSTEDSIGNING`, jsign uses an Azure access token as the store password.
Such a token expires after about one hour, so a static secret does not work for
a release. The release job gets the token with GitHub OIDC. Refer to the
[Azure setup](#setting-up-azure-trusted-signing) below.

The script signs copies of each exe. It then makes `osslsigncode verify`
examine each copy for a valid chain, a timestamp, and the expected
publisher. It replaces the exes only when all copies pass. The results are:

- `signed`: all exes have a verified signature.
- `unsigned`: `WOOTC_SIGN_STORETYPE` is empty. The release continues and the
  notes say "Not code-signed".
- `failed`: a tagged release stops. An auto or manual pre-release continues
  with the unsigned exes, and its notes say that the signature step failed.
  Thus an outage of the signature service does not stop the nightly
  releases.

When #229 is done, set the variables. Then cut a tagged
release and do the fresh-machine check above.

### Setting up Azure Trusted Signing

For #229, the maintainer selected the Azure service `Trusted Signing`.
Microsoft now calls it `Artifact Signing`, and the portal and the role
names can show either name. The release workflow is ready. It does nothing
until the variables below exist, and until then the releases ship unsigned.

**How the release job signs.** Only the `build + publish` job has
`id-token: write`, and it runs in the GitHub environment `release`.
When `WOOTC_SIGN_STORETYPE` is `TRUSTEDSIGNING` and `AZURE_CLIENT_ID` is set,
`azure/login` logs in with the OIDC token of the job. The repository keeps
no secret for this login. Immediately before the first signature,
`packaging/sign-exes.sh` gets an access token for `https://codesigning.azure.net`.

jsign then signs each exe in the release assets: `wootc.exe` and each branded
exe. The timestamp server is `http://timestamp.acs.microsoft.com`.
`osslsigncode` examines each signature. If the login or the token fails, the
result is `failed`. A tagged release stops, and a pre-release continues
unsigned with a warning in its notes.

The release job uses jsign on Linux, and not the Microsoft
`azure/artifact-signing-action`, for these reasons:

- The Microsoft action operates only on Windows runners.
- The publish job is a Linux job. It holds the private key for the
  `SHA256SUMS` signature of this release, and that key must not leave the job.
  A Windows job would split the build, the signature, and the checksums
  into three jobs.
- jsign uses the same Azure service. The workflow pins the jsign download by
  version and SHA-256.

**Do these steps in Azure.** A person with the Owner role on the subscription
must do them. The workflow does not create Azure resources.

1. In the subscription, register the resource provider `Microsoft.CodeSigning`.
2. Create an account of the service in a supported region. Record the
   account name and the account URI, for example
   `https://eus.codesigning.azure.net/`.
3. On the account, give your own user the role
   `Artifact Signing Identity Verifier`. Its old name is
   `Trusted Signing Identity Verifier`.
4. On the account, open **Identity validations** and request a **Public**
   validation for the organization. Microsoft examines the legal documents.
   The name that Microsoft validates becomes the `CN` and `O` of each
   certificate. Wait until the status is `Completed`.
5. On the account, create a certificate profile of the type **Public Trust**
   and select the completed validation. Record the profile name.
6. In Microsoft Entra ID, create an app registration, for example
   `wootc-release-signing`. Record the application (client) ID and the
   directory (tenant) ID.
7. On that app registration, add a federated credential:
   - Scenario: `GitHub Actions deploying Azure resources`.
   - Organization `tuna-os`, repository `wootc`.
   - Entity type **Environment**, name `release`.
   - The subject must be `repo:tuna-os/wootc:environment:release`, the
     issuer `https://token.actions.githubusercontent.com`, and the audience
     `api://AzureADTokenExchange`.

   A tag push, a dispatch, and the automatic channel each run under a
   different ref. The environment gives one subject for all of them.
8. Assign the role `Artifact Signing Certificate Profile Signer` to the
   service principal of that app registration. Its old name is
   `Trusted Signing Certificate Profile Signer`. Use the smallest scope:
   the certificate profile.

**Then set these repository variables** (Settings ▸ Secrets and variables ▸
Actions ▸ Variables). Do not make secrets for them:

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID` | the application (client) ID from step 6 |
| `AZURE_TENANT_ID` | the directory (tenant) ID from step 6 |
| `AZURE_SUBSCRIPTION_ID` | the subscription of the account |
| `WOOTC_SIGN_STORETYPE` | `TRUSTEDSIGNING` |
| `WOOTC_SIGN_KEYSTORE` | the host of the account URI, for example `eus.codesigning.azure.net` |
| `WOOTC_SIGN_ALIAS` | `<account name>/<certificate profile name>` |
| `WOOTC_SIGN_PUBLISHER` | the `CN` of the certificate: the validated name from step 4 |

Do not set the secret `WOOTC_SIGN_STOREPASS` or the variable
`WOOTC_SIGN_CA_PEM`. `WOOTC_SIGN_TSAURL` is optional.

The first run of the publish job makes the environment `release` if it does
not exist. If you add required reviewers to that environment, each release
waits for a reviewer, and the automatic channel waits too.

**Match the publisher name.** The UAC prompt shows the publisher from the
certificate. The **Properties ▸ Details** tab shows `CompanyName` from the
version resource of the exe. These two names must be the same.
While a brand has no `blessed` record, its exe names the distributor
`TunaOS` as its `CompanyName` (#604).
If the validated name in step 4 is a different legal name, use that name.

Change the distributor in `app/branding/ownership.json` and the `publisher`
of the generic brands. A brand with a `blessed` record names its owner as
its `CompanyName`, but the certificate still names the validated
organization. Write that difference in the `blessing.json` of that brand.

The release now builds a VERSIONINFO resource **per brand** through
`packaging/build-windows.py`. It reads the product name, description,
publisher, copyright, and file name from `app/branding/<brand>/brand.json`.
The release tag supplies the version. A tag such as `v1.2.3` also sets the
numeric version. Auto release tags stay in the text fields; their numeric
version is `0.0.0.0`.

The build uses the brand's `icon.ico` when present. Otherwise, it converts
`logo.svg` with `rsvg-convert`. If neither is usable, it reports the platform
icon fallback. A conversion error stops the build. The release job installs
`rsvg-convert`, so brands with a logo get their own icon.

The helper builds from a temporary copy of the app. It does not change the resource file in the source tree. To build a brand after the frontend build:

```sh
python3 packaging/build-windows.py --brand bazzite \
    --version v1.2.3 --output /tmp/Bazzite-Installer.exe
```

The resource tool keeps the administrator manifest, Windows compatibility,
and DPI settings. `tests/unit/test_windows_resources.py` builds
a pair of Windows files and reads their PE resource tables. It checks the brand
text, version, icon bytes, administrator request, and GUI subsystem.
The file identity does not sign the installer or set the UAC publisher.
Use the field verifier and attach screenshots for the published files.

[#241]: https://github.com/tuna-os/wootc/issues/241
[#240]: https://github.com/tuna-os/wootc/issues/240
[#229]: https://github.com/tuna-os/wootc/issues/229
[#230]: https://github.com/tuna-os/wootc/issues/230
[jsign]: https://ebourg.github.io/jsign/

## Narrative release notes

`release.yml` writes a short block that names the gate of each build. A final
tag (`vX.Y.Z` with no suffix) also needs the story of the version. That story
is in `docs/release-notes-<tag>.md`, and the publish job adds it to the
release body after that block.

`tools/release/check-notes.sh` enforces this before the E2E gate starts:

- A final tag without its notes file stops the release.
- A notes file with the marker `<!-- wootc-release-notes: draft -->` stops
  every release of that tag, including pre-release tags. Draft notes hold
  *To add* slots for evidence, and a published draft would claim proof that
  does not exist.

### Cutting v1.0.0 (#242)

[`release-notes-v1.0.0.md`](release-notes-v1.0.0.md) is a draft now.
Do these steps in order:

1. Fill each *To add* slot in the notes with its evidence (M5.1 to M5.6).
   Remove the draft marker in the PR that records the last evidence.
2. Dispatch `release.yml` with `release_tag: v1.0.0` from the final green SHA
   of the soak. Do not set `skip_e2e`. The E2E gate of the tagged channel
   runs again before the publish.
3. Monitor the `winget-publish.yml` run that the publish job dispatches, until
   `winget show TunaOS.wootc` reports `1.0.0`.
4. Change `ROADMAP.md` to the post-1.0 plan. Close the milestone issues
   #210 to #213, each with links to its evidence.
5. Announce the release in the channels that each brand agreed to
   ([upstream blessings](upstream-blessings.md)).

## When a release has to be taken back

[runbooks/rollback-a-bad-release.md](../runbooks/rollback-a-bad-release.md)
sets the decision order and verification steps for a bad release.

- Mark the bad release as a **pre-release** and explicitly select a full release that passed its tests for `latest`.
  If no full release passed its tests, remove download recommendations until a replacement passes.
- **Delete** remote assets only for a dangerous build.
  Uncached downloads can then fail; valid signed caches and offline bundles can still work.
  Removal can also break a published winget URL and cannot undo an installation.
- Revert the faulty source or pause `e2e-gui.yml`; inspect release jobs that are active too.
- Verify `SHA256SUMS.sig` with the manifest and the installer's embedded key.
  The release job discards its private seed, so a new key cannot sign a replacement for an old installer.
- Verify a merged winget withdrawal or replacement through a fresh package-source query.

## User instructions (shipped in the release notes)

1. Download `wootc.exe`. It is not code-signed yet (alpha) — SmartScreen will
   warn; *More info → Run anyway*.
2. The app checks for Windows 10/11 64-bit, UEFI + Secure Boot, TPM 2.0, and **BitLocker off** (alpha).
   It also needs at least 35 GB free on `C:`.
   This reserves 20 GB for Linux and 15 GB for Windows.
3. Run it, pick Bluefin, set a username + password, and click Install.
   Install creates the Linux disk file and changes the boot setup before you
   click **Reboot Now**. Save your work before you restart.
4. The one-time deployer boot prepares Linux. Windows normally returns after
   that boot. Open Manage and choose **Restart into Bluefin** to start Linux.

Uninstall tries to remove the installed files and boot setup. An incomplete
cleanup can leave files or boot state behind. In Manage, **Also delete my Linux
data** is a separate choice. Review that choice before you confirm removal.

## Signed boot manifests

Every new release embeds a per-build verification key and ships `SHA256SUMS.sig`.
See [artifact authentication](artifact-authentication.md) for custody, rotation,
offline bundles, and the separate gate for Windows signatures.
