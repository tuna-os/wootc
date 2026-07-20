# Phase-2 attach: debugging postmortem

**Scope.** How wootc's Phase-2 boot went from "never attaches root.disk → emergency
shell" to a working attach chain, told as the sequence of *distinct* root causes we
peeled — each proven by the next run getting further — plus the wrong turns, the
diagnostic techniques that actually worked, and the runner-ops traps that cost the
most time.

**One-line summary.** Phase 2 failed for **six independent reasons stacked on top of
each other**, one of which was a self-inflicted observability regression that masked
the others and sent us chasing phantom host bugs. Reading the built artifacts off
disk (`data.qcow2`) with libguestfs — not serial logs — is what finally cracked it.

---

## Background: the mechanism under test

wootc installs a bootc Linux image "Wubi-style": the Linux root filesystem lives in a
**raw `root.disk` image hosted on the Windows NTFS partition**. At Phase-2 boot the
initramfs must:

1. mount the Windows NTFS,
2. `losetup`-attach `root.disk` (with `--partscan` so its partitions appear),
3. let udev create `/dev/disk/by-uuid/<root>`,
4. so the ordinary `sysroot.mount` (`root=UUID=…` from the BLS entry) proceeds and
   ostree pivots.

The Phase-2 initramfs is a **pure-systemd ostree initramfs** — it never runs
`dracut-initqueue`. That single fact is the origin of half the bugs below: code
written as an initqueue hook is dead there, and the systemd replacement has to be
wired and ordered exactly right.

---

## The layers, in the order we peeled them

### 0. (Pre-session) initqueue hook → systemd service
The attach logic began as a dracut **initqueue hook**. Proven dead: the Phase-2
initramfs runs `dracut-initqueue` zero times. Replaced with a systemd oneshot
(`wootc-attach.service`) ordered `Before=sysroot.mount`, wanted by
`initrd-root-device.target`. Correct in theory — but the next four bugs were all in
*getting that service to actually exist, be wired, run, and succeed*.

### 1. Wiring written to `/etc`, verified in `/usr/lib` — regen aborted
`module-setup.sh` wired the service with `systemctl add-wants --root`, which writes
the wants symlink under **`/etc/systemd/system/…wants/`**, but the build-time check
looked in **`/usr/lib/systemd/system/…`**. When `add-wants` *succeeded* (environment-
dependent — it failed offline, so offline validation passed), the fallback `ln` was
skipped, the `/usr/lib` check found nothing, `dfatal` fired, and the **whole dracut
regen aborted**.
**Fix (`ed86d13`):** create the wants symlink directly in `$unitdir`, drop
`add-wants`, verify with `-L` (symlink exists) not `-e` (target resolves).
**Also:** `deploy.sh` now `exit 1`s on a failed regen instead of logging it as a
"problem" and booting a stale/hookless initramfs anyway.
**Real bug, but not why Phase 2 stayed broken.**

### 2. 🔥 Self-inflicted: `set -e` abort masked everything
An observability commit (`f48fcdc`) added, inside the deploy-monitor loop:
```sh
echo "$NEW_OUTPUT" | grep -aoE "guard: …" | while read gl; do info "PHASE-1 GUARD: $gl"; done
```
The script runs under `set -euo pipefail`. On the common serial chunk with **no**
guard-line match, `grep` exits 1, `pipefail` propagates it, and `set -e` **killed the
deploy-monitor loop on the very first chunk** — surfacing as `Deploying (0m)` then
failure on *every* runner.
**This masked all subsequent progress and produced two false diagnoses** (see Wrong
Turns). The one run that had reached Phase 2 cleanly (`29715469136`) simply predated
this commit.
**Fix (`421fc20`):** capture with `|| true`, then feed the loop.
**Lesson:** adding observability *under `set -euo pipefail`* is a landmine — any bare
`grep`/pipeline that can legitimately match nothing must end in `|| true`.

### 3. 🎯 Dangling wants symlink — the actual reason Phase 2 never booted
With #1 and #2 fixed, the service still never ran (`attach-loop entered = 0`, zero
systemd trace). **Found by disk archaeology:** libguestfs read the *booted* Phase-2
initramfs straight out of `data.qcow2`'s ESP (`/EFI/wootc/phase2-initramfs.img`) and
`lsinitrd`'d it. The `initrd-root-device.target.wants/wootc-attach.service` symlink
was present — but its **target `usr/lib/systemd/system/wootc-attach.service` was
absent**. A **dangling symlink**: systemd had nothing to start.
**Cause:** the *deployer's* `module-setup.sh` staged `module-setup.sh` +
`wootc-attach-loop.sh` into the deployer initramfs but **never the `.service` unit
file**, so `deploy.sh`'s `cp -a …/99wootc-boot/.` carried no unit, and the Phase-2
regen's `inst_simple "$moddir/wootc-attach.service"` silently installed nothing while
`ln -sf` still made the symlink. A leftover from the hook→service switch. The old
guard only checked the *symlink*, so it passed while the unit dangled.
**Fix (`d5365db`):** stage the `.service`; `dfatal` if the unit doesn't land; the
deploy guard now requires the unit *file*, not just the symlink.
**Result: the service ran for the first time ever (`attach-loop entered = 2`).**

### 4. Service ran, gave up before udev created the host device
The service ran, then bailed: `host NTFS … not present yet (initqueue will retry)`.
But it's a **systemd oneshot** — nothing retries. It looked before udev had processed
the Windows disk; `After=systemd-udev-trigger` only means the trigger *fired*, not
that processing finished.
**Fix (`dc44fa1`):** the script now `udevadm settle`s and polls for the host device
(up to 60s) instead of assuming a retry; unit ordered
`After=/Wants=systemd-udev-settle.service`; `udevadm` staged into the initramfs.
**Result: the host NTFS was found.**

### 5. No NTFS driver in the image at all
Now it found the NTFS and tried to mount it — and failed:
`cannot mount host NTFS rw (no ntfs3, no ntfs-3g) … ntfs3=0 ntfs-3g=no`.
**Confirmed via podman:** yellowfin (EL10, kernel 6.12) has **zero NTFS support** —
EL disables `CONFIG_NTFS3`, and `ntfs-3g` isn't installed. The deployer's runtime
ntfs-3g injection is therefore load-bearing, but it failed for **two** reasons:
- **5a.** It ran a plain `dnf install ntfs-3g`, which fails on EL because `ntfs-3g`
  lives in **EPEL**, not the base repos. **Fix (`91ff455`):** enable EPEL (+CRB)
  first. Verified against yellowfin (installs `ntfs-3g-2026.2.25.el10`).
- **5b.** Even then it failed — and the *timing* gave it away: "injecting ntfs-3g"
  and "install failed" were stamped the **same second** (a real dnf install takes
  seconds), i.e. the `podman run` **never started the container**. In the deployer's
  minimal initramfs, podman's default **netavark** path errors
  (`nft did not return successfully`) — the container netns can't be created.
  **Fix (`5ed3591`):** `podman run --network=host` reuses the deployer VM's host
  netns (the one bootc-pull already succeeds on) + its resolv.conf, skipping netavark.
**Result — the breakthrough:** `host NTFS mounted via fuse-ntfs-3g`,
`attached raw root.disk … as /dev/loop0`, `post-attach partitions: loop0p1/p2/p3`.
The FUSE userspace driver mounts the NTFS; the whole fight was just getting that
binary *into* the initramfs.

### 6. Partitions attached, but no `by-uuid` symlink → `sysroot.mount` timeout
`sysroot.mount` then waited for `dev-disk-by-uuid-<ext4 root>.device` and timed out.
The tell: the loop partition **nodes existed**, yet **not one ext4 UUID** appeared in
`/dev/disk/by-uuid/` (only the Windows disk's vfat/NTFS ones). `losetup --partscan`
creates the device nodes, but its partition-add uevents are missed when udev has
already settled by the time the service runs — so udev never `blkid`s the loop
partitions and never makes the by-uuid symlinks.
**Fix (`27fbf1f`):** after `losetup`, re-read the partition table and re-trigger udev
`add` events for the loop device + partitions, then `udevadm settle`.
**Status at time of writing: validating.**

---

## What worked

- **Disk archaeology over serial capture.** The decisive tool was
  `podman run --privileged -v storage:/s fedora … libguestfs-tools` →
  `virt-cat` / `lsinitrd` reading `deployer.log` and the **booted** initramfs
  straight out of `data.qcow2`. The serial is overwritten by later boots and the
  persisted log is unreachable once Phase 2 hits a Linux emergency shell — the disk
  has ground truth. This is now automated in CI (`e2e-hosted.yml` disk post-mortem
  step) so every hosted failure self-diagnoses, including a `::warning::` for the
  dangling-symlink signature.
- **Assert the property, not a proxy.** Every recurring bug was "status derived from
  a proxy": the guard checked the *symlink* not the *unit file*; offline validation
  checked `add-wants` return code not the symlink in the *built* image; the harness
  checked a marker's presence not that it came from *this* run. The guards now assert
  the real thing (unit file present; symlink is `-L`; `matches=` AND unit-file count).
- **`--network=host` for podman in a minimal initramfs.** bootc pull works via the
  host netns; a fresh `podman run` needs netavark+nft, which the stripped initramfs
  can't provide. `--network=host` sidesteps it entirely.
- **FUSE `ntfs-3g` as the NTFS driver.** Kernel `ntfs3` is absent on EL; the userspace
  FUSE driver is kernel-independent and the right answer — the only trick is getting
  the binary into the initramfs.
- **Confirming the fix from the *right* log level.** The `injecting`/`failed`
  same-second timestamp proved "container never started" vs "dnf failed" — a one-line
  diagnosis that decided the fix.

## What didn't work / wrong turns (and why)

- **Blaming himachal's host** for the `Deploying (0m)` deaths. It was the `set -e`
  regression (#2) aborting on *every* runner. **Lesson: identical failures across
  different hosts = a harness bug, not N host failures.** We even wiped himachal's
  storage chasing a stale-OVMF-vars theory — pure waste.
- **Filing a "restore path broke" bug (#44).** Same `set -e` regression, not a real
  restore-path defect.
- **Inferring from our own speculative error string.** deploy.sh's
  `[WARN] ntfs-3g install failed (network/repo?)` is a *guess we wrote*; acting on it
  nearly sent us to fix DNS. The real error (`podman run` never started) only showed
  in the *timing*. **Always get the actual error, not your own hypothesis string.**
- **Over-reading a Phase-2-only serial.** "The dfatal is gone → my fix worked" was
  invalid: the dfatal/regen/guard all happen in the *Phase-1 deployer* boot, absent
  from a Phase-2 serial. Know which boot your log is from.

## Runner-ops traps (the real time sink)

- **dockur names its QEMU process `windows`**, not `qemu-system`. Every
  `pkill -f qemu-system` / `ps -C qemu-system-x86_64` cleanup *silently missed*
  leaked VMs. A leaked 8 GB QEMU named `windows` starved memory and made QEMU die
  ~t=203s mid-deploy — which *looked* like a host crash but was OOM from our own
  accumulated relaunches.
- **`for d in /proc/*; do grep -qa qemu-system-x86_64 "$d/cmdline"` false-matches the
  ssh command's own shell** (its args literally contain the search string). It always
  reports phantom procs. Match `argv[1]` via `ps -eo pid,args | awk '$2=="run-e2e.sh"'`.
- **`pkill -f run-e2e` self-kills the ssh shell** (its args contain "run-e2e").
- **The E2E lock is `flock -n` on fd 9** of `storage/.run-e2e.lock`; a leaked child
  inherits fd 9 and holds it. `pgrep` misses it; find holders via `/proc/*/fd` (no
  `fuser` on himachal) and kill them, then `rm` the lock.
- **Do NOT `podman system reset` a runner to "clean up"** — it also destroys the
  user's own long-lived containers (builds, monitoring stack). A targeted clean
  (`podman rm -f wootc-e2e-windows`, clear lock, wipe `storage/` keeping `custom.iso`,
  `git reset --hard`) is enough.
- **himachal's container bridge networking hits netavark/nftables errors** — use
  `WOOTC_E2E_NETWORK_MODE=slirp4netns` for the host container. (Distinct from the
  in-VM netavark issue that `--network=host` solves for the ntfs-3g injection.)
- **himachal's `git fetch` intermittently lags a just-pushed commit** — re-fetch if
  `origin/main` looks stale.

## Infra we built along the way

- **GHCR/ORAS Windows base-image snapshot** (`e2e-snapshot.yml` + `--skip-install`
  restore) — primes a pristine, cleanly-shut-down Windows once so hosted runs restore
  in ~2 min instead of reinstalling (~20-30 min). Clean shutdown (not a live
  fsfreeze) avoids a dirty-NTFS image. Restore path needs a re-verify pass now that
  the `set -e` bug (its apparent breakage) is fixed.
- **`use_base_image` toggle** — forces a full install when needed.
- **Disk post-mortem CI step** — libguestfs auto-diagnosis on every hosted run.

## Open items

- Validate the udev-trigger fix (#6) boots Phase 2 end-to-end, then let the
  `--phase3` run graduate to native — **the 1→2→3 goal**.
- Then the **GUI-driven** leg (CDP for the Windows installer, AT-SPI/dogtail for the
  Linux Phase-3 GTK app).
- Re-verify the base-image **restore** path (was masked by the `set -e` bug).
- **Durable alternative to runtime ntfs-3g injection:** ship `ntfs-3g` in the
  yellowfin image (its Containerfile, with EPEL) or a static/musl `ntfs-3g` bundled
  in the module. Deletes the whole deploy-time-injection failure class; Phase 2 *and*
  Phase 3 both fundamentally need to mount the NTFS-hosted root.disk.

## Earlier pitfalls (from the commit history, before this session)

The layers above sit on top of a longer trail. These recur enough to be worth
naming — most are the *same failure classes* seen again this session.

### The NTFS injection has bitten repeatedly (this session was the latest layer)
- `46a767a` first identified the root cause via a **fast container repro, not a
  20-min deploy**: EL kernels ship no `ntfs3` and yellowfin ships no `ntfs-3g`, so
  the loop-attach hook can't mount the Windows volume. Introduced
  `ensure_ntfs_support()` (inject via the image's *own* repos so glibc matches).
- `469f4e7`: the injection used `podman run -d` — **detached mode does not work in
  the deployer initramfs** ("could not start the container"); all its other podman
  calls are foreground. (This session's `--network=host` fix is the *next* layer on
  the same container-won't-start problem.) Same commit: the capability probe
  **misread `CONFIG_NTFS3_FS=y`** — a built-in ntfs3 has no `.ko` and no binary yet
  mounts fine; consult `/proc/filesystems` and the kernel config, not just files.
- `b945a0d` → `24c48f8`: making injection failure a **hard error broke deploys that
  actually worked** (images with built-in ntfs3). Reverted to best-effort. Takeaway:
  the capability check is not authoritative; the runtime fallback is the real guard.

### Status-from-a-proxy false positives (the dominant bug class)
- `61e974d`: **"Phase 2 booted" fired from the initramfs** — the detector matched
  `ostree=` in the cmdline echoed by the initramfs, so a boot that then failed
  `sysroot.mount` was reported as a PASS; the *downstream* symptom (no Linux QGA)
  sent debugging to the wrong place. Require evidence of the *real* root
  (multi-user/graphical target or login), fail loud on emergency.
- `ff3f827`: a **kernel `reboot: Restarting system` was treated as deploy success** —
  but the watchdog reboots that way too. Only the deployer's *own* reboot message
  implies success.
- `aa00b24`: a **dead serial feed was silently stale** — a stale capture read as
  "quiet guest". Make it loud.

### The in-guest watchdog saga (`8187fa9` and its three predecessors)
Four attempts. The bug was **structural, not a cancellation detail**: any background
job in the deploy hook is a child of `dracut-initqueue`, and initqueue *waits for its
children* — so a watchdog blocks the very thing it guards. `( sleep; reboot ) &` never
cancelled (blocked initqueue 45 min); `+ kill/wait` blocked forever when the kill
missed; `+ setsid` put the sleep beyond both pid- and process-group-kill. Final answer:
**delete the in-guest watchdog**; the host covers all cases.

### Serial saturation (`18c8fd7`, reverting `93e87e1`)
Adding a direct `/dev/console` write to `log()` meant every line went out **three
times over a 115200 baud serial** (stdout + kmsg-forwarded + direct). During the
verbose bootc install the link saturated and a blocking console write **stalled every
deploy at `phase: verification`**. `<27>` (KERN_ERR) already reaches the console under
`quiet`, so the extra write bought nothing. Low-volume boot paths can write to
`/dev/console`; the high-volume installer must not.

### Boot-chain handoff
- `75f8be3`: **`bcdedit /set {fwbootmgr} bootsequence {GUID}` — PowerShell parsed the
  bare `{GUID}` as a script block**, bcdedit got garbage and silently failed, so the
  one-shot Phase-2 boot was *never set* and every "reboot into Phase 2" just went back
  to Windows. This is why no automated run reached a Phase-2 boot for a long time even
  after deploys succeeded. Fix: PowerShell stop-parsing (`--%`) + verify the
  bootsequence took.
- `028ab37`: the Phase-2 `grub.cfg` was written only to `/EFI/<vendor>/`, but the
  target-signed grub loads from `\EFI\fedora`, resolves its prefix to its own dir, and
  read a **stale deployer menu** → "file not found", booting neither OS. Write the menu
  to **all three prefixes** (`/EFI/{vendor,fedora,wootc}/grub.cfg`).
- `d1dd5a9`: chain systemd-boot through the Debian shim.

### Timeouts / hangs
- `c5de470`: an **unbounded `chroot dracut` regen can hang forever** and writes nothing
  to the journal — indistinguishable from a dead deployer (the 31-min silent hang).
  Bound every regen (`timeout 900`), announce it, treat a timeout as HARD failure.
- `bc504a1`: wait loops counted **ticks, not wall-clock** — measured 0.68× real, so a
  "45-min" timeout was really ~66 min and progress under-reported by half an hour.
- `4ad34e2`: **a hung QGA `exec` froze runs indefinitely** — bound every QGA call.

### Data-safety near-misses (North Star)
- `aded90f`: **the rung-3 graduate targeted "the first disk that isn't root's" — which
  in Phase 2 is the *Windows* disk** (root lives on the loopback). `bootc install
  --wipe` there destroys Windows. Fixed to pick a *blank* disk (emptiness, not
  non-rootness) — see `pick-blank-disk.sh`. Same commit: the migration **opt-out was
  cosmetic** — `wootc-manifest-gui` wrote a selection file that *nothing read*, so
  turning "Games" off still migrated Steam. Both are "shipped-looking but broken",
  caught by adversarial review.
- `4efb71c`: gate look/wifi/wsl on the chooser and make every gate **fail OPEN**.

### Harness self-harm
- `709857a`: the harness was **filling its own runners' disks** with un-pruned
  artifacts. `43xxx`/`1c6d713`: the **pre-deployer snapshot was accidentally
  load-bearing** — disabling it exposed a race the 10-20 min freeze/copy had been
  hiding as an incidental `sleep`. `54fe1db`/`70c2799`/etc.: repeated **preflight
  disk-size mis-sizing** (120 GiB excluded hosted runners; 90 was right).
- `6757300` → deleted: the **qemu-nbd self-contained closure** (26-library) failed on
  a **libfuse3 soname mismatch** — the cross-distro binary-bundling trap that also
  argues for the raw-`losetup` switch and against bundling foreign binaries.

## Commit trail

| Commit | Layer | What |
|---|---|---|
| `ed86d13` | 1 | wire wants in `$unitdir` not `/etc`; abort on failed regen |
| `f48fcdc` | (regression) | guard-verdict observability — introduced the `set -e` abort |
| `421fc20` | 2 | fix the `set -e` abort (`\|\| true`) |
| `d5365db` | 3 | stage the `.service` unit file (dangling-symlink fix) |
| `dc44fa1` | 4 | wait for the host NTFS instead of assuming an initqueue retry |
| `91ff455` | 5a | enable EPEL to install ntfs-3g |
| `5ed3591` | 5b | `--network=host` so the injection container can start |
| `27fbf1f` | 6 | udev-trigger after losetup so by-uuid symlinks appear |
