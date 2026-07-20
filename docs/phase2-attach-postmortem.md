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
