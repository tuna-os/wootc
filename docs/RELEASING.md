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
  "experimental"`. Only `green` images are offered in standard channels.
- **`app/app.go` `GetSupportPolicy()`** — per-channel gate for the *scenario*
  axes (BitLocker/FDE, custom OCI refs, encryption). The frontend reads it to
  gate the UI; `StartInstall` enforces it as the authoritative backstop.

When a matrix cell goes green, flip its `status` (and/or the relevant policy
flag) in the same PR that records the green run — never ahead of it.

## Channels

The active channel comes from `$WOOTC_CHANNEL`, else `C:\wootc\channel.txt`,
else the built-in default (`stable` on v1.0.0+, `beta`/`alpha` for pre-release tracks).

| Channel | Bar to enter | Offers |
|---|---|---|
| **alpha** | one image green end-to-end (incl. GUI-driven) | green images only; encryption off; no BitLocker; no custom refs |
| **beta** | the **full matrix** green | all images; custom refs; still gates any axis whose issue is open |
| **stable** | full matrix green + 30-day soak with no data-safety regressions | everything verified green in matrix |

## Release Channels in CI/CD

`.github/workflows/release.yml` automates releases across three paths:

1. **Tagged Channel (Full Releases):**
   - Triggered by git tag (e.g. `v1.0.0`) or `workflow_dispatch` with an explicit `release_tag` (e.g. `release_tag: v1.0.0`).
   - The workflow runs the full GUI-driven E2E gate on a hosted Windows 11 runner before building and publishing assets.
   - Builds all five branded executables (`wootc.exe`, `TunaOS-Installer.exe`, `Bluefin-Installer.exe`, `Aurora-Installer.exe`, `Bazzite-Installer.exe`) via `app/branding/*/brand.json` and `packaging/brands.sh`.
   - Generates deployer boot artifacts (`deployer-vmlinuz`, `deployer-initramfs.img`, `shimx64.efi`, `grubx64.efi`, `mmx64.efi`) and `SHA256SUMS`.
   - Publishes the GitHub Release as non-prerelease.
   - Dispatches `.github/workflows/winget-publish.yml` to automatically submit/update `TunaOS.wootc` in `microsoft/winget-pkgs`.

2. **Automated Pre-Release Channel (Nightlies):**
   - Triggered on `workflow_run` completion after a green nightly GUI E2E run on `main`.
   - Cuts `auto-vYYYYMMDD-<sha>` tagged pre-release from the proven commit SHA.
   - Serves as the continuous daily proof ledger for the 1.0 soak gate (`docs/soak.md`).

3. **Manual Pre-Release Channel:**
   - Triggered via `workflow_dispatch` without an explicit release tag for test/debugging builds.

## Cutting a Full Release (e.g. v1.0.0)

Cutting a full release requires no special tag-push permissions on developer workstations:

1. **Verify Prerequisites & Evidence:**
   - Soak ledger (`docs/soak.md`) confirms 30 consecutive qualifying green days.
   - Full-tier matrix run on `e2e-matrix.yml` is green at the release commit.
   - Narrative release notes prepared in `docs/release-notes-<version>.md` (e.g. `docs/release-notes-v1.0.0.md`).
2. **Dispatch the Release:**
   ```bash
   gh workflow run release.yml --repo tuna-os/wootc -f release_tag=v1.0.0
   ```
3. **Shepherd winget Auto-Submission:**
   - `release.yml` triggers `winget-publish.yml` with `tag=v1.0.0`.
   - `winget-publish.yml` downloads the published `wootc.exe`, hashes it, renders manifests into `rendered/manifests/t/TunaOS/wootc/<version>`, and submits the PR to `microsoft/winget-pkgs` via `wingetcreate`.
   - Monitor the PR on `microsoft/winget-pkgs` until merged.
4. **Milestone Rollover:**
   - Close milestone tracking issues (e.g. #210, #211, #212, #213) with comments linking to their verification evidence.
   - Roll `ROADMAP.md` forward to the next horizon track.

## User Instructions (Shipped in Release Notes / INSTALL.md)

1. Download `wootc.exe` (or your preferred branded installer, or run `winget install TunaOS.wootc`).
2. Requirements checked by the app: Windows 10/11 64-bit, UEFI + Secure Boot, TPM 2.0, ~40 GB free disk space.
3. Run the installer, select your Linux image, set your username and password, and click **Install**. Nothing on your PC changes until you click **Reboot Now** — and even then, Windows and all your files remain untouched; Linux lives safely inside `root.disk`.
4. First boot displays a calm setup screen for 5–15 minutes while Linux initializes.
5. To return to Windows, reboot and select Windows from the boot menu.
6. To uninstall wootc: run `wootc.exe uninstall` or use Windows **Settings → Installed Apps → Uninstall** (restores boot entries, power settings, ESP, and cleans `C:\wootc`).
