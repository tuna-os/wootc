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
