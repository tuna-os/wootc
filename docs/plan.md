# wootc Implementation Plan — Remaining SPEC Coverage

*Generated 2026-07-17 from the GUI/Phase-1 worktree session.*

## State at handoff

Two active lanes running in parallel across 3 E2E hosts:

| Lane | Branch | Host(s) | Status |
|------|--------|---------|--------|
| GUI / Phase 1 | `worktree-gui-phase1` | dilli (local), kanpur | 5 commits ahead of main; LUKS backend dirty |
| VHDX / Phase 2 | `explore/vhdx-root-disk` | himachal, dilli | Deployer reaches fisherman; partitioning NBD race fixed; OCI export fix landed |

Fisherman fork (`tuna-os/fisherman`) is unarchived, `dev` branch carries both fixes.
Communication between tracks: `handoff.md` (untracked, live file in main checkout).

---

## Remaining SPEC items (ranked by impact × independence)

### 1. LUKS encryption (§2.6) — IN PROGRESS

**Backend**: plumbed but uncommitted. `InstallConfig.Encryption` (`"none"` | `"tpm2-luks"` | `"luks-passphrase"`) + `LuksPassphrase` field. grub.cfg forwards `wootc.luks=<type>` on the cmdline.

**Remaining**:
- [x] Commit the dirty `app/app.go` + `app/installer_windows.go` changes (→ `4543d8b`)
- [ ] Add `Encryption` field to non-Windows `getSystemInfo()` stub
- [x] GUI: encryption section on launchpad (radio: None / TPM auto-unlock / Passphrase) — **source written, not yet built**
- [x] GUI: passphrase input field — **source written, not yet built**
- [x] Frontend binding: `Encryption` + `LuksPassphrase` in `startInstall()` — **source written**
- [x] Playwright test: encryption chooser — **test written, fails (stale dist/)**
- [x] `.gitignore`: add `*caveat*.txt` exports

**BLOCKER**: Playwright serves the **built** bundle from `app/frontend/dist/`.
Source changes don't appear until `cd app/frontend && npm run build`.
The LUKS test fails because `dist/` still has the old bundle.

**Next**: rebuild frontend, re-run Playwright (expect 10/10 green).

---

### 2. NTFS defrag preflight (§3.6)

**What**: Before creating root.vhdx, check the NTFS volume's fragmentation level. If heavily fragmented, offer to defrag so VHDX extent allocation is reasonably contiguous (performance, not correctness).

**Implementation**:
- [ ] Add `defragRecommended` to `SystemInfo` — call `defrag C: /A /V` and parse "You should defragment this volume"
- [ ] GUI: warning banner on launchpad when defrag recommended, with a "Defrag now" button
- [ ] Backend: `DefragDrive()` exported method — runs `defrag C: /U /V` (admin)
- [ ] Playwright: defrag warning scenario

**Files to touch**: `app/installer_windows.go`, `app/installer_other.go`, `app/app.go`, `app/frontend/src/main.js`, `tests/gui/gui.spec.js`

---

### 3. VM modes detection (§6.1, §6.2)

**What**: Detect whether the Windows host has WHPX (Hyper-V) or HAXM available for accelerated VM boot. Bundle a minimal QEMU for Windows so "Boot in VM" works out of the box.

**Already done**: `app/vm_windows.go` (QEMU launcher), `app/vm_other.go` (stubs), "Boot in VM" button on control panel.

**Remaining**:
- [ ] Bundle QEMU for Windows (or document that the user needs to install it)
- [ ] Detect WHPX: check `Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All`
- [ ] Detect HAXM: check for Intel HAXM driver
- [ ] `GetVMCapability()` returns richer info: which accelerator, QEMU path, whether QEMU is bundled
- [ ] "Boot in VM" button shows disabled state with reason when no accelerator
- [ ] If QEMU not found, offer download link or bundle path

**Files to touch**: `app/vm_windows.go`, `app/vm_other.go`, `app/installer_windows.go`, `app/frontend/src/main.js`

---

### 4. systemd-boot option (§1.2)

**What**: Offer systemd-boot as an alternative bootloader in the UI. However, systemd-boot won't chain-load under Secure Boot for EL targets (shim only signs GRUB). For a non-Secure-Boot or UKI future, add it as a hidden/advanced option.

**Implementation**:
- [ ] Add `"systemd-boot"` to the bootloader dropdown (hidden behind an "Advanced" toggle)
- [ ] Backend: stage `systemd-bootx64.efi` on ESP, write loader entries for the deployer
- [ ] Document: Secure Boot limitation — this path only works with SB off or a future signed UKI

**Files to touch**: `app/frontend/src/main.js`, `app/installer_windows.go`, `app/app.go`

---

### 5. polkit policy hookup

**What**: The migration helpers (`wootc-convert-dir`, `wootc-apply-look`) currently use `pkexec` with a generic prompt. Ship a polkit policy so the prompt reads "TunaOS migration needs to…" instead of a raw binary path.

**Already done**: `org.tunaos.wootc.policy` file exists.

**Remaining**:
- [ ] Wire it into deploy.sh's migration install block (copy the .policy to /usr/share/polkit-1/actions/)
- [ ] Verify `pkaction --action-id org.tunaos.wootc.convert-dir` works post-install
- [ ] Test: run `wootc-convert-dir` as non-root, confirm the polkit dialog text

**Files to touch**: `payload/deployer/deploy.sh`, `payload/migration/org.tunaos.wootc.policy`

---

### 6. CI — Playwright on PRs

**What**: Run the Playwright mock suite on every PR, and the CDP (real wootc.exe) suite on a Windows self-hosted runner.

**Implementation**:
- [ ] GitHub Actions workflow: `tests/gui/` Playwright suite (Linux, 9 tests)
- [ ] GitHub Actions workflow: `tests/gui/cdp.spec.js` on Windows self-hosted runner (gated by `WOOTC_CDP_URL`)
- [ ] Upload screenshots as artifacts
- [ ] Block merge on failure

**Files to touch**: `.github/workflows/gui-tests.yml` (new)

---

### 7. Cleanup

**What**: Git hygiene items from the session.

- [ ] Add `*caveat*.txt` to `.gitignore`
- [ ] Add `app/wootc` (built binary) to `.gitignore`
- [ ] Commit `docs/gui-phase1-architecture.md`
- [ ] Delete the stale conversation export: `app/2026-07-17-042039-local-command-caveatcaveat-the-messages-below.txt`

---

## Dependency graph

```
LUKS backend commit (1a)
    └── LUKS GUI wiring (1b)
            └── LUKS Playwright test (1c)

NTFS defrag preflight (2) ─── independent

VM modes detection (3) ─── depends on QEMU bundling decision

systemd-boot option (4) ─── independent, low priority

polkit hookup (5) ─── independent

CI (6) ─── independent, but benefits from all tests passing

Cleanup (7) ─── do first
```

---

## Next steps (order of execution)

1. **Cleanup** — commit dirty files, add gitignore entries
2. **Finish LUKS** — GUI wiring + test (unblocks "all SPEC" claim)
3. **NTFS defrag preflight** — quick win, no dependencies
4. **polkit hookup** — quick win, already have the .policy file
5. **VM modes detection** — needs QEMU-bundling decision first
6. **systemd-boot** — low priority, hidden option
7. **CI** — benefits from all tests green
