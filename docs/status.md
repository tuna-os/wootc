# Verification status — what is proven, on what evidence

This page carries the detailed red/green state that used to live in the
README: what has been proven end-to-end, on which rigs, with which caveats.
The [ROADMAP](../ROADMAP.md) says where the project is going; this page says
what the evidence supports today. The verification ladder itself is defined
in [milestones.md](milestones.md).

A case is only marked ✅ once the whole chain passes: Windows seed → deploy →
Phase-2 boot → seeded file readable from Linux.

## Proven end-to-end (KVM E2E rig: Windows 11 + TPM 2.0 + Secure Boot)

- ✅ **Arm (rung 1):** the real `wootc.exe` arms a virgin Windows VM over QGA —
  root disk, signed chain, one-shot BCD, `state.json = armed` (24/24).
- ✅ **Deploy:** the Secure Boot chain launches the deployer and fisherman lays
  down a full bootc image into `root.disk` — every post-deploy check passes
  (dracut hook, services, loop-root BLS args, ESP kernel-sync, `host-esp.conf`).
- ✅ **Native Phase-2 boot (rung 2):** the signed Windows BCD → shim → GRUB
  chain boots the installed Bluefin system from the NTFS-hosted `root.disk`.
  The initramfs mounts NTFS with the kernel driver, attaches the raw disk with
  `losetup`, resolves the root UUID, runs OSTree prepare-root, switches to the
  real deployment, reaches the graphical system, and exposes Linux QGA.
- ✅ **GUI + migration:** installer GUI (Playwright-tested), User Data Bridge
  and WSL/Office/Steam/browser bridges (unit-tested), external-disk import
  engine, Try-in-VM orchestration, Phase-3 planner.
- ✅ **Graduate to native disk (Phase 3 / rung 3):** the VM boots Phase 2,
  independently verifies a blank `/dev/sdb`, runs the native `bootc install`,
  reboots into the graduated system, and confirms the file seeded in Windows
  survived onto the native disk — Windows and `root.disk` untouched (29/29).
- ✅ **GUI-driven full run:** the entire Phase-1 → 2 → 3 chain armed by the
  **real `wootc.exe` GUI** (drive mode — the app drives its own live form),
  green end-to-end on `bluefin:lts`. The timelapse on the
  [walkthrough page](https://tuna-os.github.io/wootc/e2e/latest/) is that run.
- ✅ **E2E-gated releases:** `v0.1.0-alpha.1` was published only after a fresh
  full GUI-driven run passed on the exact tagged commit; nightly green runs cut
  automatic pre-releases from the SHA they proved.

## Build/test matrix

Red/green status per combination, from the KVM E2E rig (laptop runners) and
the hosted-runner matrix (`.github/workflows/e2e-matrix.yml`). Legend:
✅ proven green · 🟡 in progress / partially proven · 🔴 known-red (tracked
issue) · ⚪ not yet run.

**Last full matrix sweep: 2026-07-25 — 12 of 22 cases green**, with targeted
re-runs since (dates on the affected rows).

> ⚠️ **The ✅s below predating 2026-07-27 are currently UNVERIFIED** (per-row
> exceptions are called out — e.g. the `dakota` composefs cell was re-proven on
> the failure-ledger harness on 2026-08-02). Until commit
> `3d7f9e2`, `fail()` only printed — a failed check that did not itself
> abort could not stop the run reaching "ALL TESTS PASSED". A real BitLocker run
> was recorded PASS with `[FAIL] User data NOT visible in Phase 2 $HOME` in its
> own log, which is the North Star assertion itself. The harness now records
> every failure to a ledger and gates the banner on it, so this class of false
> green cannot recur — but the counts above were produced by the old harness and
> are being re-run. Treat them as claims awaiting evidence, not as status.

> ℹ️ **Resolved (2026-07-27):** the hosted-runner TPM blocker
> ([#59](https://github.com/tuna-os/wootc/issues/59)) was ours, not GitHub's —
> our sshd wrapper took PID 1 from `tini`, so `swtpm`'s `-d` daemonization never
> wrote its pid file and dockur silently disabled TPM. Fixed in `4a087eb`;
> GitHub-hosted runners are back in scope.

**Image family × phase** (Windows 11 Pro, Secure Boot + TPM 2.0):

| Image family | Backend / rootfs | Arm (P1) | Deploy | Phase-2 boot | Phase-3 graduate | GUI-driven full run |
|---|---|:--:|:--:|:--:|:--:|:--:|
| `bluefin:lts` | ostree · ext4-sealed | ✅ | ✅ | ✅ | ✅ (29/29) | ✅ |
| `yellowfin:gnome` (EL10) | ostree · ext4-sealed | ✅ | ✅ | ✅ | ✅ | ⚪ |
| `yellowfin:kde` / `:xfce` (EL10) | ostree · ext4-sealed | ✅ | ✅ | ✅ | ⚪ | ⚪ |
| `bonito:gnome` / `:kde` / `:niri` (Fedora) | ostree · **xfs** (unsealed) | ✅ | ✅ | ✅ | ⚪ | ⚪ |
| `dakota` | composefs-native | ✅ | ✅ | 🔴 [#209](https://github.com/tuna-os/wootc/issues/209) | ⚪ | ⚪ |
| `marlin` (Arch) / `flounder` (Debian) | ostree · xfs (unsealed) | ✅ | 🔴 | ⚪ | ⚪ | ⚪ |

`dakota` (composefs-native) went green on the failure-ledger harness —
composefs full chain, run `30710282014` (2026-08-02);
[#28](https://github.com/tuna-os/wootc/issues/28) is closed. Its Phase-2
**first boot after a clean GUI deploy** currently hangs CPU-bound
([#209](https://github.com/tuna-os/wootc/issues/209), 2026-08-22) — being
root-caused for v0.2.0-alpha. `marlin`/`flounder` fail in
`bootc install` with *"bootupd is required for ostree-based installs"*: they are
ostree images that ship no `bootupd`.

**Axes** (against the EL10 / `bluefin:lts` baseline):

| Axis | Status | Notes |
|---|:--:|---|
| Windows 11 Pro | ✅ | primary proven path |
| Windows 11 Home / Enterprise / LTSC | ✅ | all three green on EL10 |
| Windows 10 Pro | ✅ | green in 37 min via the restored Windows base image |
| Windows 10 Home / Enterprise / LTSC | 🔴 | Setup stops on its edition picker — the answer file's product key matches no image in the ISO for those editions — [#58](https://github.com/tuna-os/wootc/issues/58) |
| Root filesystem: `xfs` (unsealed) | ✅ | mounted with explicit `-t` (a typeless mount tried ext4 on xfs) |
| Root filesystem: `ext4` (sealed, fs-verity) | ✅ | proven sealed default |
| Root filesystem: `btrfs` (sealed) | ✅ | green cell on bonito via `wootc.filesystem=btrfs` (2026-08-22); blocked on EL10 kernels whose out-of-tree btrfs kmod is rejected under Secure Boot |
| Encryption: none | ✅ | |
| Encryption: `tpm2-luks` | 🟡 | [#33](https://github.com/tuna-os/wootc/issues/33) fixed (`bffd284`, 2026-08-10) — Phase-2 dracut regen works; green cell re-verification pending under the failure-ledger harness |
| BitLocker FDE (unencrypted-volume path) | ✅ | refusal path green 2026-08-22; full install path is the v0.3.0-beta gate — [#34](https://github.com/tuna-os/wootc/issues/34). Setup carves unencrypted volume E: for `root.disk` while C: stays encrypted |
| Offline (`-nic none`, pre-downloaded image) | ⚪ | code path shipped (branded builds / `WOOTC_PRELOAD=1`); matrix axis tracked as [#217](https://github.com/tuna-os/wootc/issues/217) |

The full three-phase chain (Windows seed → deploy → Phase-2 bridge →
Phase-3 native disk → seeded file on the native disk) is **green end-to-end
on `bluefin:lts`** — both via the script path (29/29) and driven entirely
through the real `wootc.exe` GUI (drive mode), and it gates every release.

## Running the E2E yourself

The E2E harness drives a Windows 11 VM (via
[dockur/windows](https://github.com/dockur/windows)) over the QEMU Guest
Agent — no guest networking required. It needs a host with KVM, UEFI Secure
Boot, and TPM 2.0.

```bash
just remote-sync               # push + reset a runner to origin/main
just remote-e2e                # fresh install + deploy (~30 min)
just remote-e2e-quick          # reuse the installed disk (~5 min)

just remote-logs               # tail the run
just remote-serial             # watch the deployer serial console
just remote-status             # grep PASS/FAIL markers
```

Every E2E run records a sped-up timelapse to
`tests/e2e/storage/artifacts/<run>/video/`. To refresh the
[walkthrough](https://tuna-os.github.io/wootc/e2e/latest/) on the README,
publish a passing run's clip:

```bash
tests/e2e/publish-visual.sh --from-host <host>   # or a local artifact dir
git add pages && git commit -m 'docs: refresh E2E walkthrough' && git push origin main
```

A GitHub-hosted workflow (`.github/workflows/pages.yml`) then deploys it to
Pages — no self-hosted runner required. The README hero is a committed
relative path, so it renders inline on GitHub even before Pages redeploys.
