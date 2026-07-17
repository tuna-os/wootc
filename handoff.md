# Handoff — 2026-07-17 (GUI Phase 1 + VHDX + Fleet Status)

## Overall State

Two active lanes: **VHDX/Phase-2** (on `explore/vhdx-root-disk`, runner: himachal/dilli)
and **GUI/Phase-1** (on `worktree-gui-phase1`, working from isolated worktree
`.claude/worktrees/gui-phase1/`). The GUI branch is 5 commits ahead of main and
includes the VHDX branch as its base. A third worktree at `/tmp/wootc-main` points at `main`.

**Fisherman fork** (`tuna-os/fisherman`, unarchived): branch `dev` now carries the NBD
fix + PR#11 OCI-export fix (merged via PR #47). The wootc submodule in **both**
branches points at tuna-os/fisherman `dev` (`ea4b08e`).

Communication between tracks: this file (`handoff.md` in the main checkout root).
It is intentionally **untracked** — each session reads it directly.

---

## GUI / Phase-1 Track

**Location**: `.claude/worktrees/gui-phase1/` · **Branch**: `worktree-gui-phase1`
**Status**: 5 commits ahead of origin/main, **uncommitted LUKS encryption work in progress**

### Committed and pushed (6ff077f):

| Commit | SPEC | What |
|--------|------|------|
| `a89fdb8` | §3.5 | BitLocker chooser in GUI — never forces decrypt; offers unencrypted partition (reuse existing or create new) |
| `9a89737` | §3.5, §5, §3.1 | BitLocker backend (`bitlockerState`, `CreateDataPartition`, `listDataPartitions`), full uninstall with partition-aware options, SHA256 checksum verification |
| `3beedce` | §5 | Uninstall panel: checkbox for "delete root.disk", partition-reclaim option; defaults to reversible |
| `6ff077f` | §6.2, §3.6 | Boot-in-VM button (QEMU WHPX on root.disk, `app/vm_windows.go`), TRIM/discard passthrough (`--discard=unmap`) |
| `6a9acf8` | — | Submodule pinned to tuna-os/fisherman `dev` |

**Playwright**: 9/9 mock tests green (gui.spec.js). CDP spec (cdp.spec.js) is Windows-only, gated by `WOOTC_CDP_URL`.

**Screenshots generated**: 9 (launchpad, image grid, install progress, done, control panel, BitLocker, branded, office migration, VM mode).

### Uncommitted (in the worktree):

1. **`app/app.go`** + **`app/installer_windows.go`**: LUKS encryption plumbing
   - `InstallConfig.Encryption` field: `"none"` | `"tpm2-luks"` | `"luks-passphrase"`
   - `InstallConfig.LuksPassphrase` field
   - grub.cfg forwards `wootc.luks=<type>` on the cmdline
   - **NOT committed yet** — needs the GUI wiring (encryption-options section on launchpad) and the non-Windows stubs

### What's left to implement from the SPEC:

| Pri | SPEC | Feature | Dependencies |
|-----|------|---------|-------------|
| 1 | §2.6 | LUKS encryption UI (wire the already-plumbed backend into the GUI) | None |
| 2 | §6.1 | VM modes — bundle QEMU, detect WHPX availability | Bigger piece, need QEMU bundling story |
| 3 | §3.6 | NTFS defrag preflight (not just TRIM) | Windows-only |
| 4 | §1.2 | systemd-boot option in UI (likely hidden — won't chain under Secure Boot for EL) | Low priority |
| 5 | — | polkit policy for migration helpers (already shipped but needs hookup) | None |
| 6 | — | CI: run Playwright suite on PRs | GitHub Actions |
| 7 | — | CI: CDP spec on a Windows self-hosted runner | Windows runner |

### What to do next on this track:

1. **Commit the LUKS plumbing** (it's sitting dirty in the worktree)
2. **Wire LUKS into the GUI** — add a "Linux disk encryption" section on the launchpad with radio buttons: None / TPM auto-unlock (recommended) / Passphrase
3. **Add Playwright test** for the LUKS chooser (new screenshot scenario)
4. **Open a PR** to merge `worktree-gui-phase1` into main (or rebase first — the branch is 5 commits ahead)

---

## VHDX / Phase-2 Track

**Location**: main checkout · **Branch**: `explore/vhdx-root-disk`

### Current status:

- **kanpur** (main/raw disk): last run got through OEM → deployer → fisherman, failed at OCI export (`skopeo copy: exit status 2`). The OCI fix (PR#11) is now in the fisherman submodule — next run should get further.
- **himachal**: ISO verified, synced, ready for VHDX branch runs.
- **dilli**: ISO verified, deployer rebuilt with the NBD fix. Last attempt: partitioning failed at `sfdisk --wipe=always ... /dev/nbd0: exit status 1`. Likely NBD not fully settled; try `blockdev --rereadpt /dev/nbd0` before sfdisk.

### Fisherman fork status:

- `tuna-os/fisherman` is **unarchived** and in working order
- `dev` branch = upstream `38d418f` + NBD fix + PR#11 OCI fix
- **NBD fix** (`ea4b08e`): skips `fuser -km` on `/dev/nbd*` (the "holder" is qemu-nbd itself)
- **OCI fix** (PR#11, two commits): fixes podman store coherency during OCI export
- Two pre-existing upstream test failures remain (noexec /tmp env, missing OCI runtime) — NOT introduced by our fixes

### Known risks (from VHDX review):

| Risk | Severity | Description |
|------|----------|-------------|
| R1 | CRITICAL | qemu-nbd killed at switch-root — systemd kills initramfs processes. Fix: `exec -a @qemu-nbd` or kernel-side NBD |
| R2 | HIGH | Fedora qemu-nbd binary in EL target — glibc symbol version mismatch risk |
| R3 | MED | /dev/nbd0 EBUSY on initqueue retries (already hit this, fix in deploy.sh) |
| R4 | MED | qemu's VHDX log-replay may not be crash-safe when qemu is the writer |

---

## Fleet Status

| Host | Role | Branch | Status |
|------|------|--------|--------|
| **kanpur** | E2E runner (raw disk) | main | Last run: OCI export failure. Fisherman fix now available |
| **himachal** | E2E runner (VHDX) | explore/vhdx-root-disk | Ready: ISO verified, synced |
| **dilli** | E2E runner (GUI Phase 1) | worktree-gui-phase1 | Ready: ISO verified, deployer rebuilt with NBD fix |
| **local** | Dev workstation | — | Two worktrees active. GUI branch has dirty LUKS work |

### Runner prep checklist (for any host):

```bash
# Fix root-owned files
sudo chown -R james:james ~/wootc/tests/e2e

# Kill stale processes
kill $(pgrep rootlessport) 2>/dev/null
sudo kill $(pgrep qemu-system) 2>/dev/null
podman stop wootc-e2e-windows 2>/dev/null && podman rm wootc-e2e-windows 2>/dev/null

# Ensure podman-compose is available
pip install podman-compose  # if needed

# Sync submodules (important — fisherman fork pointer changed)
git submodule sync && git submodule update
```

### Running E2E:

```bash
cd ~/wootc/tests/e2e
sudo chown -R james:james .
kill $(pgrep rootlessport) 2>/dev/null
sudo kill $(pgrep qemu-system) 2>/dev/null
podman stop wootc-e2e-windows 2>/dev/null && podman rm wootc-e2e-windows 2>/dev/null
PATH="$HOME/.local/bin:$PATH" nohup bash run-e2e.sh --keep > /tmp/wootc-e2e-qgaN.log 2>&1 &
```

Monitor: `ssh <host> 'tail -f /tmp/wootc-e2e-qga*.log'`

---

## Key Files to Know About

| File | Purpose |
|------|---------|
| `handoff.md` | **This file** — live inter-session communication (untracked) |
| `docs/gui-phase1-architecture.md` | GUI architecture doc (untracked, needs committing) |
| `docs/vhdx-exploration.md` | VHD/VHDX design decision record |
| `docs/milestones.md` | Verification ladder (rung 1 green, rung 2 next) |
| `docs/architecture-boundary.md` | bootc/generic seam — what stays outside deploy.sh's provisioner region |
| `docs/gui-walkthrough.md` | Screenshot walkthrough of the installer GUI |
| `app/vhd.go` | VHD footer builder (Go) |
| `app/vm_windows.go` | QEMU VM launcher (Windows, WHPX) |
| `app/vm_other.go` | VM stubs (non-Windows) |
| `app/state.go` | Lifecycle state bus (`C:\wootc\state.json`) |
| `app/helpers.go` | Shared helpers (downloadFile, copyFile, marshalJSON, sha256, unmarshal) |
| `tests/gui/` | Playwright suites (gui.spec.js 9/9, cdp.spec.js Windows-only) |
| `tests/e2e/phase1/` | Phase-1 E2E (headless wootc.exe, 24/24 green) |
| `tests/migration/test-bridge.sh` | Migration tests (33/33 green) |
| `tests/e2e/record-video.sh` | Screendump timelapse → PR comment |

---

## Git Hygiene Notes

1. **`handoff.md`** is untracked by design — it's the live comms channel
2. **`docs/gui-phase1-architecture.md`** is untracked — should be committed
3. **`app/2026-07-17-...caveat...txt`** is a Claude Code conversation export — delete or gitignore
4. **`app/wootc`** (built binary) is tracked and shows dirty — add to `.gitignore`
5. The GUI worktree has dirty files (`app/app.go`, `app/installer_windows.go`) — LUKS encryption plumbing, uncommitted
6. **Two worktrees active**: `.claude/worktrees/gui-phase1` and `/tmp/wootc-main`
