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

- **Image:** `ghcr.io/projectbluefin/bluefin:lts`. This combination passed the full cycle, including a run through the GUI.
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
# → tests → E2E gate (real Windows VM, bluefin:lts, GUI-driven) → build + publish
```

Every release ships the **full artifact set** from `release.yml`.
It includes one installer per brand directory: `wootc.exe`,
`TunaOS-Installer.exe`, `Bluefin-Installer.exe`, `Bazzite-Installer.exe`, and
`Aurora-Installer.exe`. These use Wails with Go and a web UI, with no runtime dependencies.

The shared boot artifacts are `deployer-vmlinuz`, `deployer-initramfs.img`,
`shimx64.efi`, `grubx64.efi`, and `mmx64.efi`.
The set also includes `wubildr.efi` when its build succeeds.
`SHA256SUMS` lists hashes for all these files. `skip_e2e` exists for emergencies and
documents itself in the release notes.

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
| each asset matches `SHA256SUMS` | `Get-FileHash` against the published manifest; an asset the manifest does not list fails rather than being skipped |
| each exe is Authenticode-signed | `Get-AuthenticodeSignature` must be `Valid` *and* name a signer. `HashMismatch` is called out separately — that is a tampered download, not an unsigned one |
| each branded exe shows its own identity | the exe's VERSIONINFO `ProductName`/`FileDescription`/`CompanyName` match that brand and contain no "wootc" |

A person must attach three screenshots, because a script cannot make them:
- The UAC prompt.
- The **Properties ▸ Details** tab of the exe.
- The SmartScreen interstitial, or a note that it did not show.

### Signatures and file identity

**No release has a signature.** `release.yml` has no step that signs the
files. [#229] is the choice and purchase of a signature method. This is a
spend decision for the maintainer. [#230] adds that method to the pipeline.
Until both issues are done, each signature box is ✘. SmartScreen shows the
wall for unknown apps, and UAC shows "unknown publisher".

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
[#229]: https://github.com/tuna-os/wootc/issues/229
[#230]: https://github.com/tuna-os/wootc/issues/230

## When a release has to be taken back

[runbooks/rollback-a-bad-release.md](../runbooks/rollback-a-bad-release.md)
is the other direction: which lever to pull for a bad build, and what each
one reaches. The short version, because the instinct is usually wrong:

- Mark the bad release as a **pre-release** to move `latest` back to the last good full release.
  This repairs download links and unstamped builds. Pinned exes can still verify their files.
- **Delete** the release to reach an exe already on a user's disk.
  This also makes published winget manifests return 404. Use this action for a dangerous build.
- The nightly continues to publish `auto-v*` from `main`.
  Revert the faulty commit or pause `e2e-gui.yml` to stop further releases.
- Submit a PR against `microsoft/winget-pkgs` to withdraw a winget version.

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
