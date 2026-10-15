# Docs truth pass — the record

Every checkable claim in the user-facing docs, walked against the build and
marked ✔ or ✘ (#233). This file is a **dated record of a pass**, not a live
status page: it says what was true on a given commit and what was done about
what wasn't. The live enforcement is `tests/unit/docs-truth.bats`, which turns
each ✘ found here into a test so the same drift fails CI instead of a reader.

---

## Pass 1 — 2026-09-02, against `94025c5`

**Scope:** `README.md`, `docs/getting-started.md`, `docs/user-guide.md`,
`docs/manual-testing.md`, `docs/branded-walkthroughs.md`, `docs/branding.md`,
`docs/branding-and-distribution.md`, `docs/RELEASING.md`.

**Method:** static — every claim checked against the shipping source (Go,
frontend JS, workflows, `images.json`, `brand.json`), with the two
channel-dependent behaviours confirmed by running the real resolvers
(`effectiveBranding()`, `GetSupportPolicy()`, `GetImages()`) rather than
reading them. **Not** a VM walk; see *Still open* below for what that leaves.

### ✘ Found and fixed (9)

| # | Where | Claimed | Actually |
|---|---|---|---|
| 1 | `getting-started.md` §4 | first screen reads *"Try Linux alongside Windows — no repartitioning, nothing deleted, and fully undoable"* | reads **"Bring Windows to Linux — keep everything."** The quoted string is the JS fallback in `launchpad.js`, and `defaultBranding()` always sets a tagline — so the fallback is unreachable in every build |
| 2 | `manual-testing.md` bug-report table | installer state at `C:\wootc\install\state.json` | `C:\wootc\state.json` (`app/state.go`). `C:\wootc\install\` does exist (`wifi/`, `slurp/`), which is why the wrong path read as plausible |
| 3 | `manual-testing.md` §Before you start | *"The app refuses to start on battery"* | the app opens; it disables **Install** with *"Plug in the power adapter first"* — and only when a battery is actually detected (`onBattery && batteryKnown`), so a desktop is never blocked |
| 4 | `user-guide.md` footer | loop *"verified end-to-end on real hardware (UEFI + Secure Boot + TPM 2.0)"* | evidence is the KVM VM rig (`status.md`). Real-hardware evidence is the **unmet** v0.2.0-alpha gate in `ROADMAP.md` |
| 5 | `RELEASING.md` §User instructions | instructions shipped in *"the release notes / INSTALL.md"* | no `INSTALL.md` exists anywhere in the tree |
| 6 | `RELEASING.md` | *"The published artifact is `wootc.exe`"* | `release.yml` publishes one exe **per brand** plus `deployer-vmlinuz`, `deployer-initramfs.img`, `shimx64.efi`, `grubx64.efi`, `mmx64.efi`, best-effort `wubildr.efi`, and `SHA256SUMS` |
| 7 | `README.md` "What you get", `user-guide.md` §1 and §7 | *"BitLocker-safe"*, *"BitLocker is fine too"*, *"wootc offers to put Linux on an unencrypted partition"* | `BitLockerSupported: false` on **alpha and beta**; `gateScenario()` hard-refuses and the Install button is disabled. `manual-testing.md` and `RELEASING.md` already said so — the user guide contradicted them, and a BitLocker reader would have downloaded and hit a wall the guide said was not there |
| 8 | `user-guide.md` §2 | *"The default (Yellowfin GNOME)"* | `main.js` pre-selects `images[0]`; in alpha `GetImages()` returns green images in file order, so the default is **Bluefin LTS** — which `RELEASING.md` §Alpha already named |
| 9 | `user-guide.md` §4 | the *"Bring your setup over"* dashboard | the app calls it **"Bring Over From Windows"** (`wootc-manifest.desktop`, `wootc-manifest-gui`). That label existed nowhere in the product |

Also aligned, having found the docs disagreeing with each other and with the
code: the free-space figure. The launchpad gates on `maxDiskSizeGB() < 20`
with `DISK_HEADROOM_GB = 15`, i.e. **35 GB**; `user-guide.md` and
`RELEASING.md` both said "~40 GB" while `manual-testing.md` said 35.

### ✔ Checked and correct (spot-check, not exhaustive)

**Paths** — `C:\wootc`, `C:\wootc\disks\root.disk`, `C:\wootc\logs\`,
`C:\wootc\logs\deployer.log`, `C:\wootc\logs\deployer-last-journal.log`,
`C:\wootc\channel.txt`, `C:\wootc\brand.json`, `C:\wootc\brand.css`,
`C:\wootc\bundle\oci`.

**Registry** — the Add/Remove entry is `TunaOS (wootc)` for the generic build
(`displayName = b.Name + " (wootc)"`), as `getting-started.md`,
`user-guide.md` §9 and `manual-testing.md` all say.

**Commands and env** — `wootc.exe uninstall`, `winget install TunaOS.wootc`,
`WOOTC_PRELOAD=1`, `WOOTC_CHANNEL`, `wootc.debug`, `just test`, `just build`,
`npx playwright test`.

**Channel behaviour** — default channel `alpha`; alpha offers green images
only, no custom OCI refs, no BitLocker; the alpha image is
`ghcr.io/projectbluefin/bluefin:lts`; `images.json` carries
`"status": "green" | "experimental"` as `RELEASING.md` describes.

**On-screen strings** — "Restart into &lt;distro&gt; →", "Also delete my Linux
data", "Make it feel like Windows", the disabled-Install reasons.

**Exe names** — `Bazzite-Installer`, `Bluefin-Installer`, `Aurora-Installer`,
`TunaOS-Installer` all match their `brand.json` `exeName`, and the docs
advertise no exe that no brand builds.

**Links and images** — every relative `.md`/`.png` link in the scoped docs
resolves; all 20 branded walkthrough screenshots and all 12 GUI walkthrough
screenshots are present.

**Catalog** — GNOME / KDE Plasma / Niri / XFCE on el10 / fedora / arch /
debian, as README and the user guide describe.

### Still open — needs the RC build and a VM

These are **not** ✔ and were not claimed as such. They cannot be settled from
a checkout, and the issue's done-when depends on them:

- [ ] Walk each doc against an actual RC build in a Windows VM.
- [ ] **Timings**: "5–15 minutes on a fast line", "30–60 minutes on a slow
      connection", "a few minutes". Measured, not asserted.
- [ ] **SmartScreen behaviour post-signing.** Every SmartScreen and "unknown
      publisher" paragraph is written for unsigned binaries. Signing is a 1.0
      criterion in `ROADMAP.md`; when it lands, `getting-started.md` §2–3,
      `README.md` and `RELEASING.md` §1 all change together.
- [ ] **Add/Remove rendering** — that `TunaOS (wootc)` is what Settings shows,
      not just what the installer writes.
- [ ] **Regenerate every screenshot from the RC SHA.** Deliberately not done
      here: the GUI and branded sets regenerate from the Playwright suites and
      the timelapse comes from the nightly, so regenerating them from `main`
      would date them to the wrong build. They must be dated from the RC.

### Code observation, left alone

`launchpad.js` renders `state.brand?.tagline || '<long fallback>'`. No build
can reach that fallback — `defaultBranding()` sets a tagline and every
`brand.json` overrides it — and finding ✘1 means it has already misled a
reader once, via a doc that quoted it. Removing it is a frontend change and
was out of scope for a docs pass; `docs-truth.bats` now pins the doc to the
real `brand.json` tagline instead, so the two cannot drift again.

## Focused guide pass — 2026-09-27, against `85a032f`

This pass compares the user guide with current source and retained VM evidence.
It is not a walk through an RC build on real hardware.

Four incorrect claims now have checks in `tests/unit/docs-truth.bats`:

- The guide said the deployer restarts into the new desktop.
  Windows normally returns first. The Manage screen offers an explicit Linux boot choice.
- The guide excluded all passwords from profile imports.
  The Firefox helper copies a complete profile, including saved passwords.
- Windows removal appeared as an available final step in the guide.
  The helper prints a plan. The helper has no consumer execution for that plan.
- Exact restoration of Windows after uninstall appeared in the guide.
  Cleanup can fail. The guide now describes its intended actions and reported errors.

The guide also states the limits of VM-first use, native graduation, and hardware evidence.
Its OS requirements stay the same. Earlier section anchors still resolve.
The revised text has no English findings under the shared checker.
RC timing, fresh package screenshots, hardware recovery, and signature acceptance remain open.

## Focused release gate pass — 2026-09-27, against `79fbb1e`

The release guide said that a tag proves migration to Linux and back.
The tagged workflow selects GUI install and native graduation with `phase3: true`.
It ends in graduated Linux. It checks the seeded file there.
It does not prove a Windows return after graduation.

The guide now states those observations, the automatic channel's selected stages,
and the emergency waiver. A check in `tests/unit/docs-truth.bats` pins the claim
to the tagged workflow and the runner's native boot check.
The RC walk, signature checks, and hardware acceptance remain open.

## Focused release instructions pass — 2026-09-27, against `fa50144`

The release guide still had three incorrect user instructions after the guide pass.
Install creates the Linux disk and changes boot setup before the restart button.
The one-time deployer boot normally returns to Windows. Manage offers the Linux boot choice.
Uninstall attempts cleanup and can leave files or boot state behind.
Linux data removal is a separate choice in Manage.

Three checks in `tests/unit/docs-truth.bats` pin these corrections to current source.
The release instructions no longer promise a fixed first-boot time.
RC timing, package screenshots, hardware recovery, and signature acceptance remain open.

## Release guide English pass — 2026-09-27, against `5354e42`

The release guide now has no findings under the shared English checker.
Its gates, artifact names, channel limits, and requirements remain the same.
All 24 checks in `tests/unit/docs-truth.bats` pass.
The count for the repository falls from 1671 to 1635. The budget follows that count.

## Focused first-screen guide pass — 2026-09-27, against `5354e42`

The first-screen guide still limited all preparation to a folder and a boot entry.
Install also writes boot files to the EFI system partition and changes Windows startup settings.
The guide promised restoration after uninstall. Cleanup can fail, and Linux data removal is a separate choice.

The guide also guaranteed warnings and explained them only as a lack of downloads or a signature.
Microsoft documents checks for file and publisher reputation, including negative reputation and policy limits.
The guide now links that source and qualifies the prompts and continuation choices.
A checksum match and publisher identity are separate facts. The app also checks a signature on the boot manifest.

Four new docs-truth cases pin the corrections. The fresh-machine RC screenshots remain open.

## Runtime dependency follow-up — 2026-09-27, against `119bbc0`

The release guide said that the Wails installers have no runtime dependencies.
The first-screen guide said there is nothing to install.
The current Wails interface needs WebView2. The GUI path in E2E checks for that runtime and installs it if absent.
Both guides now disclose that dependency. A fifth check pins it to the actual bootstrap command and registry check.

## Roadmap claims and English pass — 2026-09-27, against `323b7ba`

The roadmap still said phases B–E had not started. A draft native preview now
has hosted component proof. Complete native consumer and VM journeys remain unproved.
It also listed console flash as an active defect; maintainers closed issue #179.
These status corrections do not certify the replacement shell.

The history implied that current uninstall restores the machine. Cleanup can fail.
Restoration remains a 1.0 requirement that needs evidence.
The RC list also treated a signature as a guarantee against SmartScreen.
The roadmap now needs a separate fresh-machine observation, as the startup guide does.
The goal of a first launch through that gate remains unchanged.

Three new docs-truth checks reject the previous roadmap claims.
The roadmap has no findings under the shared English checker.
Its milestone requirements, headings, links, tables and earlier issue references remain.

The default shared scan does not include ROADMAP.md. Its count and budget stay at 1627.
A direct scan of the roadmap falls from 68 findings to zero.
RC, hardware, complete native journeys, signatures and the 30-day soak still need proof.

## README claims and English pass — 2026-09-27, against `7a87f04`

The README promised the complete Linux-inside-Windows journey, but current desktop evidence does not prove it.
It now separates that product goal from the native install path.
The old text also limited preparation to disk and boot setup and promised complete cleanup.
It now describes startup settings, partial cleanup and separate data removal.

The release description promised a Windows return after each normal tagged run.
That workflow selects native graduation and ends in Linux. The manual waiver also exists.
The caption and release text now describe that evidence boundary.
The blanket exclusion of secrets conflicted with imports of complete Firefox profiles.
The README now discloses saved passwords in that profile, the WebView2 dependency and signed manifest checks.

Six new docs-truth checks reject the previous README claims.
The revised README has no findings under the shared English checker.
The total falls from 1627 to 1589; the budget follows that count.
Headings, existing link targets, tables, executable names, commands and license terms remain.
The native journey, real hardware, signatures, full restoration and the soak still need proof.

## E2E architecture truth and English pass — 2026-09-27, against `8e696f3`

The page called its whole description validated, although its diagrams recorded the Kanpur design from July.
It now separates those historical diagrams from current modules and dated acceptance evidence.
The complete VM journey and WinUI journey still need proof.

The page said transport, host lifecycle and retention still needed separate modules.
Main now has sourceable adapters for those operations and VM startup.
The page now identifies their actual source files and preserves the open GUI and scenario boundaries in #383.
Controlled checks do not replace fresh VM acceptance.

The page also claimed an atomic menu handoff on the ESP.
The deployer writes a separate `grub.cfg` for each of three directories.
The page now discloses partial boot state after interruption and keeps transactional recovery as a separate gate.
The argument for the kernel requests QGA; it does not prove an active service.
Four new docs-truth checks reject the old claims.

The architecture page falls from 28 English findings to zero.
Its headings, tables and diagrams remain; earlier dated records remain.
The shared count falls from 1589 to 1561, and the budget follows that count.
RC, hardware, firmware, signatures, restoration and the soak still need proof.


## Pass — 2026-09-27, manual native hardware trials

Checked the preparation and recovery claims in `docs/manual-testing.md` against
source `09f2698`. This is a static review, not a hardware run.
`tests/unit/docs-truth.bats` pins the three corrections.

| Result | Previous claim | Source and correction |
|---|---|---|
| ✘ | Everything lives in one folder; no repartitioning | `app/disk_windows.go` can resize Windows and create a data partition. `app/app.go` changes power settings and stages ESP files. The guide describes those changes. |
| ✘ | Only the folder and one boot entry exist before reboot; failure returns Windows after 30 seconds; uninstall puts everything back | Preparation also changes the ESP, registry and power state. The deployer requests a reboot; that request does not prove a Windows return. `app/installer_windows.go` reports incomplete cleanup. The guide requires observed return and baseline comparison. |
| Scope gap | The manual journey has no shell or VM boundary | The steps cover the legacy Wails native path. They do not prove the VM desktop or WinUI journey. Those gates need their own tests on hardware. |

Code samples, tables and the participant protocol remain unchanged.
Hardware, timings and firmware outcomes still need the RC walk.
