# Branded installer walkthroughs

This page has automated screenshot walkthroughs for each brand build
(`docs/branding-and-distribution.md`). A test makes these images; nobody
selects them by hand. `tests/gui/branded-walkthrough.spec.js` assembles each
brand's real embedded assets from `app/branding/<brand>/`. These are the same
brand.json, logo, typeface and theme that a `-X main.brandID=<brand>` binary
compiles in.

The test drives the real frontend bundle through the four
journey screens. On each screen, it asserts that the build shows its own
name, mark and look. A branded build must never show the word "wootc".
When you run the Playwright suite again, it refreshes each image below.

**Live video walkthroughs:** each distribution that passed a full
GUI-driven E2E has its own timelapse in the gallery at
**https://tuna-os.github.io/wootc/e2e/** . In each timelapse, a real Windows
VM installs that image through the real GUI. It then moves the user data and
goes back to Windows. The most recent green run of each image is always at
[/e2e/latest/](https://tuna-os.github.io/wootc/e2e/latest/). Cuts publish
automatically on green (`e2e-gui.yml`), one directory per distribution.

Each brand has the same journey:

1. **launchpad**: the brand's catalog, with its default image selected.
2. **progress**: the reassurance screen in the brand's look.
3. **done**: the success screen with the brand's own mark.
4. **manage**: the branded way back in ("Restart into …") and the way out.

## Bazzite — "The next generation of Linux gaming"

| | |
|---|---|
| ![Bazzite launchpad](screenshots/brands/bazzite/01-launchpad.png) | ![Bazzite progress](screenshots/brands/bazzite/02-progress.png) |
| ![Bazzite done](screenshots/brands/bazzite/03-done.png) | ![Bazzite manage](screenshots/brands/bazzite/04-manage.png) |

### Bazzite brand test record

This record is for the `-X main.brandID=bazzite` build (`Bazzite-Installer.exe`).
Each row has one check, the result, and the evidence.
A unit test or a mock GUI test is not proof that the product works on a computer.
Only the hosted E2E rows show that.

| Check | Status | Evidence |
|---|:--:|---|
| Name, product, exe and publisher never say "wootc" | ✅ | `TestBazziteBuild_WearsItsOwnIdentity` (`app/bazzite_brand_test.go`) |
| Catalog is `bazzite`, then `bazzite-deck`, with `bazzite` selected | ✅ | `TestBazziteBuild_OffersOnlyBazziteImages`; launchpad screenshot above |
| Image refs are `ghcr.io/ublue-os/bazzite:stable` and `bazzite-deck:stable` | ✅ | `TestBazziteBuild_OffersOnlyBazziteImages` |
| Both images use GRUB2 without composefs and queue the `universalblue` MOK enrollment | ✅ | `TestBazziteBuild_OffersOnlyBazziteImages`; `tests/unit/mok-enrollment.bats` |
| The default channel (alpha) still offers the default image | ✅ | `TestBazziteBuild_DefaultChannelStillOffersTheDefaultImage` |
| No custom image field, on every channel | ✅ | `TestHideCustomImage_TightensPolicy`; walkthrough launchpad test |
| The image downloads on Windows, so the deployer needs no network | ✅ unit, ⚪ E2E | `TestBazziteBuild_PreloadsTheImageOnWindows`. The E2E sets `WOOTC_PRELOAD=0`, so no run proves this path ([#217](https://github.com/tuna-os/wootc/issues/217)) |
| Logo, typeface and theme are in the exe; nothing comes from the network | ✅ | `TestBazziteBuild_AssetsNeverFetchAtRuntime` |
| Light-mode and dark-mode Windows both get the Bazzite look | ✅ | `TestBazziteBuild_ThemeIsNotConditionalOnColorScheme`; walkthrough test "a light-mode Windows still gets the brand look" (`05-light-mode.png`) |
| Add/Remove entry and the restart notice say "Bazzite" | ✅ | `TestBazziteBuild_WindowsSurfacesNeverSayWootc` |
| Recovery messages never say "wootc" | ✅ | `TestBazziteBuild_RecoveryMessagesNeverSayWootc` |
| Launchpad, progress, done, manage, uninstall dialogs, interrupted, recovery and failed-run screens never say "wootc" | ✅ | `tests/gui/branded-walkthrough.spec.js`. Windows paths such as `C:\wootc\disks` are the on-disk contract, so the test ignores them |
| The done screen shows the MokManager step and its password | ✅ | walkthrough test "done celebrates the brand" |
| Exe version resource: product "Bazzite Installer", file `Bazzite-Installer.exe`, company "Universal Blue" | ✅ | local `packaging/build-windows.py --brand bazzite` build, read with `pefile` (2026-10-15) |
| The release builds the exe, and the log names it as unblessed | ✅ | `tests/unit/brand-blessings.bats`; `packaging/brands.sh explain` |
| winget manifests render into `Bazzite.Installer` and are not submitted | ✅ | `tests/unit/brand-blessings.bats`; `packaging/winget/render-brand.sh bazzite` |
| Hosted GUI E2E, `bazzite:stable`: install, MOK under Secure Boot, Phase 2, user data, Windows return | ✅ 2026-08-24 | [run 32679831098](https://github.com/tuna-os/wootc/actions/runs/32679831098) on `4fd4bc8` |
| Hosted GUI E2E, `bazzite:stable`, current `main` | 🔴 inconclusive | [run 38731850924](https://github.com/tuna-os/wootc/actions/runs/38731850924) on `13afd74` (2026-10-15). The harness built the Bazzite installer, but its first drive report did not come in 60 s. Nothing was installed. This is the launch deadlock that [PR #516](https://github.com/tuna-os/wootc/pull/516) addresses |
| Hosted GUI E2E, `bazzite-deck:stable`, current `main` | 🔴 inconclusive | [run 38731854579](https://github.com/tuna-os/wootc/actions/runs/38731854579) on `13afd74` (2026-10-15). The same launch failure stopped it before the install |
| Hosted GUI E2E, `bazzite:stable`, branch of PR #516 (launch fix) | 🔴 inconclusive | [run 38735109866](https://github.com/tuna-os/wootc/actions/runs/38735109866) on `2eb7791` (2026-10-15). The Bazzite installer started, selected `ghcr.io/ublue-os/bazzite:stable` (no image mismatch), and the harness clicked Install. Then "Making room for Linux" stopped with "root.disk already exists". The bluefin run of that branch stopped with the same error, so the cause is not specific to Bazzite |
| Phase 3 (graduate to a native disk) with Bazzite | ⚪ | not run |

Gaps that this page does not close:

- The firmware boot entry, the deployer GRUB menu ("Install wootc"), and the data volume label (`wootc-data`) still say "wootc".
  They are part of the on-disk contract. A Bazzite user can see them in the firmware boot menu, the GRUB menu, and File Explorer.
- `matrix.tsv` has no Bazzite cell. The script path (`setup-wootc.ps1`) does not queue the MOK enrollment, so only the GUI path can prove Bazzite.

## Bluefin — "The next generation Linux workstation"

| | |
|---|---|
| ![Bluefin launchpad](screenshots/brands/bluefin/01-launchpad.png) | ![Bluefin progress](screenshots/brands/bluefin/02-progress.png) |
| ![Bluefin done](screenshots/brands/bluefin/03-done.png) | ![Bluefin manage](screenshots/brands/bluefin/04-manage.png) |

## Aurora — "Simply delightful"

| | |
|---|---|
| ![Aurora launchpad](screenshots/brands/aurora/01-launchpad.png) | ![Aurora progress](screenshots/brands/aurora/02-progress.png) |
| ![Aurora done](screenshots/brands/aurora/03-done.png) | ![Aurora manage](screenshots/brands/aurora/04-manage.png) |

## TunaOS

| | |
|---|---|
| ![TunaOS launchpad](screenshots/brands/tunaos/01-launchpad.png) | ![TunaOS progress](screenshots/brands/tunaos/02-progress.png) |
| ![TunaOS done](screenshots/brands/tunaos/03-done.png) | ![TunaOS manage](screenshots/brands/tunaos/04-manage.png) |

## wootc (generic)

The un-branded engine, as shipped today — also covered by the main
[GUI walkthrough](gui-walkthrough.md).

| | |
|---|---|
| ![wootc launchpad](screenshots/brands/wootc/01-launchpad.png) | ![wootc progress](screenshots/brands/wootc/02-progress.png) |
| ![wootc done](screenshots/brands/wootc/03-done.png) | ![wootc manage](screenshots/brands/wootc/04-manage.png) |
