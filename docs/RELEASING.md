# Releasing wootc — the green-gated ladder

wootc writes Linux onto a stranger's only computer. The release rule follows
directly from the North Star (*a nervous Windows user must not lose data*):
**the app only ever offers scenarios the E2E matrix has actually proven
green.** Everything else is hidden until it is proven. Features unlock as the
matrix greens; the channel graduates when whole tiers are green.

## The single source of truth

The [build/test matrix](status.md#buildtest-matrix) is authoritative. A
combination is *green* only when the hosted E2E (`e2e-matrix.yml` /
`e2e-gui.yml`) has passed it end-to-end — Windows seed → deploy → Phase-2
bridge → Phase-3 native disk → seeded file on the native disk.

Two places consume that status, and they must agree:

- **`app/data/images.json`** — each image carries `"status": "green" |
  "experimental"`. Only `green` images are offered in alpha.
- **`app/app.go` `GetSupportPolicy()`** — per-channel gate for the *scenario*
  axes (BitLocker/FDE, custom OCI refs, encryption). The frontend reads it to
  gate the UI; `StartInstall` enforces it as the authoritative backstop.

When a matrix cell goes green, flip its `status` (and/or the relevant policy
flag) in the same PR that records the green run — never ahead of it.

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

- **Image:** `ghcr.io/projectbluefin/bluefin:lts` — the one combination green
  end-to-end, including a full GUI-driven run.
- **Encryption:** off only. `tpm2-luks` (Phase-2 regen, [#33](https://github.com/tuna-os/wootc/issues/33))
  and BitLocker FDE ([#34](https://github.com/tuna-os/wootc/issues/34)) are
  gated off; the app detects BitLocker and tells the user plainly that it is
  coming soon rather than proceeding into a known failure.
- **Root filesystem:** ext4 (sealed default). btrfs is blocked
  ([#35](https://github.com/tuna-os/wootc/issues/35)).
- **No custom OCI refs** — only the offered, tested image.

## The unlock path to beta

Each of these flips a gate the moment its matrix row is green:

- [x] yellowfin / bonito / marlin / flounder full three-phase → `status: green`
- [x] composefs-native (dakota) Phase-2/3
- [x] Windows 10 + Home/Enterprise/LTSC editions
- [x] BitLocker FDE path (#34) → `BitLockerSupported: true`
- [ ] tpm2-luks root (#33) → offer encryption
- [ ] btrfs sealed Phase-2 (#35) → offer btrfs
- [x] custom OCI refs (once the deploy path is family-agnostic green) → `CustomImageAllowed: true`

When the **whole matrix** is green, the default channel becomes `beta`
(catalog all-green, custom refs on), and the axis gates open as their issues
close.

## Cutting a release

Releases are **E2E-gated** — tagging publishes nothing until a real Windows VM
has migrated to Linux and back on a hosted runner (`release.yml` → the gate
calls the same reusable E2E the nightly proves, on the alpha image, GUI-driven).

```
git tag v0.1.0-alpha.1 && git push origin v0.1.0-alpha.1
# → tests → E2E gate (real Windows VM, bluefin:lts, GUI-driven) → build + publish
```

Every release ships the **full artifact set**, not just one exe
(`release.yml`): one installer per brand directory — `wootc.exe` plus
`TunaOS-Installer.exe`, `Bluefin-Installer.exe`, `Bazzite-Installer.exe`,
`Aurora-Installer.exe` (Wails, Go + web UI; no runtime deps) — the shared
boot artifacts (`deployer-vmlinuz`, `deployer-initramfs.img`, `shimx64.efi`,
`grubx64.efi`, `mmx64.efi`, plus `wubildr.efi` when its build succeeds), and
a `SHA256SUMS` covering all of them. `skip_e2e` exists for emergencies and
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

### Two boxes fail today, and that is correct

The script reports ✘ now. The checklist keeps these gaps visible, so that
people do not forget them:

1. **No release has a signature.** `release.yml` has no step that signs the
   files. [#229] is the choice and purchase of a signature method. This is a
   spend decision for the maintainer. [#230] adds that method to the
   pipeline. Until both issues are done, each signature box is ✘.
   SmartScreen shows the wall for unknown apps, and UAC shows
   "unknown publisher".

2. **No build has a VERSIONINFO resource at all.** Thus the fourth item of
   criterion 4 has nothing to check. The properties dialog in its screenshot
   is blank. `just build-icon` makes `app/rsrc_windows_amd64.syso` with
   `rsrc -ico -manifest`. **`rsrc` writes an icon and a manifest only.**
   The `info` block in `app/wails.json` (`companyName`, `productName`,
   `productVersion`, `copyright`) has data that no shipped binary gets.
   The cause is that the release uses plain `go build`, not `wails build`.

   To confirm this on a build:

   ```sh
   cd app && GOOS=windows GOARCH=amd64 go build -ldflags "-X main.brandID=bazzite" \
       -o /tmp/Bazzite-Installer.exe .
   # the PE resource directory holds ICON, GROUP_ICON and MANIFEST — no VERSION
   ```

   This gap is also a brand problem, not only a signature problem. All five
   builds link the same `.syso`, and `-ldflags -X main.brandID=…` cannot
   change a resource. So the version data must be **per brand**, and the
   build must make it for each brand. If not, the properties dialog of each
   branded exe shows `wootc`. Criterion 4 forbids that text.

   The person who does [#230] changes this build loop, so that person must
   also do this work. `rsrc` cannot do it, so the tool must change too.

   The new tool **must keep the manifest**. `wootc.manifest` has
   `requestedExecutionLevel level="requireAdministrator"`. Without it, the
   installer does not ask for administrator rights, and no error shows.
   `tests/unit/fresh-machine-trust.bats` checks for this.

[#241]: https://github.com/tuna-os/wootc/issues/241
[#229]: https://github.com/tuna-os/wootc/issues/229
[#230]: https://github.com/tuna-os/wootc/issues/230

## When a release has to be taken back

[runbooks/rollback-a-bad-release.md](../runbooks/rollback-a-bad-release.md)
is the other direction: which lever to pull for a bad build, and what each
one reaches. The short version, because the instinct is usually wrong:

- Marking the bad release a **pre-release** moves `latest` back to the last
  good full release — that fixes the download links and every unstamped
  build, and leaves pinned exes able to finish verifying.
- **Deleting** the release is the only thing that reaches an exe already on
  a user's disk, and it also 404s any published winget manifest. Reserve it
  for a build that is dangerous, not merely broken.
- The nightly keeps cutting `auto-v*` from `main`, so nothing is contained
  until the offending commit is reverted or `e2e-gui.yml` is paused.
- winget submission is one-directional; withdrawing a version means a PR
  against `microsoft/winget-pkgs`.

## User instructions (shipped in the release notes)

1. Download `wootc.exe`. It is not code-signed yet (alpha) — SmartScreen will
   warn; *More info → Run anyway*.
2. Requirements the app checks for you: Windows 10/11 64-bit, UEFI + Secure
   Boot, TPM 2.0, **BitLocker off** (alpha), and at least 35 GB free on `C:`
   (20 GB for Linux plus the 15 GB headroom the launchpad reserves for
   Windows).
3. Run it, pick Bluefin, set a username + password, click Install. Nothing on
   your PC changes until you click **Reboot Now** — and even then Windows and
   all your files stay put; Linux lives in a file beside them.
4. First boot shows a calm "Setting up your new Linux system" screen for
   5–15 minutes. When it finishes you're in Linux. To go back to Windows,
   reboot and pick Windows — or uninstall wootc from inside it (deletes a
   folder and a boot entry).

Uninstalling is always: delete `C:\wootc` and remove the "wootc" boot entry —
the app's Control Panel does both.
