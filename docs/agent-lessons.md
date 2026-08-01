# Agent lessons — sharpening the axe

Hard-won knowledge from working on wootc's boot chain and E2E harness. Written
after a session where **six distinct harness defects** made real failures
unattributable, and where roughly half the failures were self-inflicted.

Read this before touching the E2E harness, the deployer, or the runners. Most
entries cost at least one 60–90 minute VM run to learn.

---

## 1. The dominant bug class

**Status derived from a proxy rather than from an observable.**

Every serious defect found in this session was an instance of it. When adding
any check, ask: *what does this assert, and what would it print if the thing it
asserts never happened?*

Real examples, all shipped and all wrong:

| Check | Passed when | Consequence |
|---|---|---|
| `qga_read marker >/dev/null` | a **stale** marker from a previous run existed | harness monitored a deployer that was never staged |
| Phase-2 boot checks | advisory only | `ALL TESTS PASSED` for a boot that never happened |
| `compose_up_windows` (return ignored) | always | 15-minute wait, then "QEMU did not start" — wrong cause entirely |
| `snapshot_serial` failure swallowed | `podman cp` failed silently | harness read a frozen serial file for 2 hours |
| `[ -f "$PTY" ]` | a previous run's file existed | a run analysed another run's serial |
| counter `ELAPSED` | never | timeouts 1.5× nominal; progress lines off by 30 minutes |

**Rule:** a check must fail when the underlying thing is absent. Prove that by
mutation-testing it — break the code and confirm the test goes red.

## 2. Liveness: what lies and what doesn't

Three liveness signals lied during this session:

- **`pgrep -f "run-e2e.sh"` over ssh** matches *your own ssh command*, because
  the pattern appears in its command line. Reported runs as alive that did not
  exist. Use `pgrep -f ... | grep -v $$`, or better, don't use pgrep.
- **`systemctl --user is-active`** is meaningless on a host where the run was
  launched with `nohup` rather than `systemd-run`. Know how it was started.
- **Log tail** lies when `StandardOutput=file:` (truncates) is combined with
  `StandardError=append:` on the same file — old stderr survives into the new
  run's log and interleaves. Use the same mode for both, and locate the current
  run by its `Run ID` line.

**What has never lied:**

- **log mtime** (`stat -c %Y`) — is the run writing?
- **guest CPU** — `podman exec <c> ps -eo pcpu,args | grep qemu-system`
- **the process tree** — `systemctl --user status <unit>` shows children;
  a `sleep 3` child means a poll loop is running, not a hang.

## 3. Serial silence is not death

`bootc install` produces **no serial output for 10+ minutes** while extracting
layers. Time-since-last-write alone is not a failure signal and will cry wolf.

**The discriminator is guest CPU:**

- silence + high CPU (130–170%) → working normally
- silence + idle CPU → actually wedged

This is why a deploy that looked hung for 13 minutes was fine, and why another
that looked identical was dead. Check CPU before concluding anything (#40).

## 4. Timeouts must be wall-clock, and bounded at the blocking call

Two separate defects here:

**Counter-based loops drift.** `ELAPSED=$((ELAPSED+5))` next to `sleep 5` does
not measure time — every blocking call in the loop body (QGA probes,
snapshotting) burns real time without advancing it. Measured drift: **0.68× wall
clock**, so "45 minutes" was really ~66. Use `deadline_in`/`past_deadline`.

*Recurred 2026-07-22* in `wootc-attach-loop.sh`: a "60s" host-NTFS wait added
3s per iteration while `udevadm settle` returned instantly on an empty queue —
the budget burned in ~2 wall-seconds, before the virtio-scsi bus was scanned,
and Phase 2 fell to the emergency shell. kmsg timestamps are the drift
detector (claimed 60s; entered 1.07s, exited 3.37s). In an initramfs use a
`/proc/uptime` deadline plus an **unconditional** per-iteration `sleep` —
never let a probe's exit status gate the sleep. Guarded in
`raw-loopback.bats` ("wall-clock with an unconditional sleep").

**A wall-clock deadline cannot rescue a loop whose body never returns.**
`qga_call` had no timeout, so a hung `podman exec` froze the loop forever and
the deadline was never evaluated. Every blocking external call needs its own
`timeout`.

**Corollary:** fixing the clock made budgets honest and revealed they had never
been calibrated against real time. Expect this — an accurate measurement often
exposes a second problem that the inaccuracy was hiding.

## 5. Removing something can expose what it was hiding

The pre-deployer snapshot spent 10–20 minutes doing an fsfreeze + 28 GiB copy.
It was **accidentally load-bearing as a `sleep`**: it gave Windows OEM setup the
time it needed to stage BootNext. Disabling it (correctly — see §7) exposed a
long-standing race where the barrier passed instantly on a stale marker.

Both changes were right. But when you remove a slow step, watch for races it was
masking, and replace the delay with a **real check**, never another sleep.

## 6. Testing traps in this repo

- **`/tmp` is `noexec` on the dev box.** PATH stubs written to
  `BATS_TEST_TMPDIR` cannot execute, so every "nothing was called" assertion
  passes **vacuously**. `setup()` must create a stub, run it, and fall back to
  `$HOME/.cache` if it fails. See `go-native.bats`, `pick-blank-disk.bats`.
- **Case-sensitive guards cover only what you thought of.** A regression test
  matching `$ELAPSED` reported green while three lowercase `$elapsed` loops were
  still broken.
- **A test can match its own documentation.** A guard grepping for
  `need at least` matched the comment block explaining the guard, not the code,
  and reported a bug that did not exist.
- **Mutation-test anything that matters.** Break the code, confirm red, restore.
  Every safety test in this repo should have been through this.

## 7. Runner operations

- **Never `podman system prune -af` on a host with a live run.** It killed three
  runs simultaneously, and separately deleted the locally-built
  `wootc-e2e-windows-ssh:latest` image, which then caused compose to try pulling
  from a registry literally named `localhost`.
- **`loginctl enable-linger <user>`** is required, or systemd kills the run when
  your ssh session closes. Runs died ~10 minutes after disconnect until this was
  set.
- **Launch with `systemd-run --user`**, passing `XDG_RUNTIME_DIR` and `HOME`
  explicitly, or rootless podman resolves *root* storage paths and fails with
  `permission denied` on `/run/containers/storage`.
- **Check for a live run before any cleanup.** Disk pressure is real, but so is
  killing an hour of work.
- **Prefer GitHub hosted runners** (`e2e-hosted.yml`, ubuntu-latest with
  `/dev/kvm`). The laptops each failed differently: podman storage drift, a KVM
  regression after `podman system migrate`, and an undersized 238 GiB disk.

## 8. Domain knowledge worth keeping

**dracut/printk logging.** Neither `info()` nor `warn()` is reliable in an
initramfs:
- `info()` writes `<30>` (KERN_INFO) and only echoes to stderr when
  `DRACUT_QUIET != yes` — which `check_quiet()` defaults to `yes`.
- `warn()` writes `<28>` (level 4), but `quiet` sets `console_loglevel=4` and
  printk prints only levels **strictly below** it — so warn is dropped too.

Use `<27>` (KERN_ERR, level 3) to kmsg. **Do not also write to `/dev/console` in
high-volume paths** — `deploy.sh` emitting every line three times saturated a
115200-baud serial and stalled every deploy. Low-volume boot hooks may.

**Windows VSS freeze limits.** `guest-fsfreeze-freeze` on Windows goes through
VSS, which enforces ~10s for writers and ~60s overall. A freeze held across a
20-minute copy is not honoured — the guest auto-thaws mid-copy, so the "crash
consistent" snapshot is not, and the volume can be left dirty.

**NTFS dirty bit.** `ntfs3` refuses a dirty volume **even read-only**. A volume
formatted by Windows and rebooted immediately is dirty. Mount fallbacks:
`ntfs3` → `ntfs3 -o ro,force` → `ntfs-3g`. This was the BitLocker bug (#36).

**Cross-image binaries need their whole closure.** The target bootc image ships
no `qemu-nbd`, so the deployer stages its own — but the deployer is Fedora-based
and the initramfs is assembled from the *target's* libraries. Measured skew:
`libfuse3.so.4` vs `.so.3` (a soname **major** bump). The binary lands and dies
at runtime, failing exactly like a missing one.
- Ship the **full closure**: binary + every `NEEDED` lib + the loader, invoked as
  `ld.so --library-path <dir> <binary>`.
- **Never** symlink `.so.4` onto `.so.3` — a soname major bump is an ABI break,
  and this driver writes the root filesystem.
- **Never** match the deployer base to the target image — wootc supports
  arbitrary bootc images, so target library versions are unknowable.
- `ldd` reports only the **first** missing library. Test by actually running the
  binary in the target image.

**Container probes report the host kernel.** `/proc/filesystems` inside
`podman run` shows the *host's* kernel, not the image's. It says nothing about
whether the image's kernel supports ntfs3. This produced one wrong root cause
already.

## 9. Diagnosis discipline

Wrong root causes reached confidently in one session: "EL10 lacks NTFS support",
"multi-disk layout breaks Phase 2", "the deploy wait has no timeout", "netavark
errors are killing the deploy", "the QGA MSI was re-downloaded with hardened
defaults". Each felt convincing.

What actually worked:

1. **Reproduce outside the VM when possible.** The qemu-nbd library mismatch was
   diagnosed *and* its fix verified in a container in minutes, versus a 90-minute
   run. Always ask: can this be tested without booting?
2. **Check the discriminator before asserting.** Guest CPU for silence. Marker
   contents for barriers. `ldd` inside the *target* image, not the host.
3. **n=1 is not evidence.** The multi-disk hypothesis came from one run per arm.
4. **Compare against a known-good run** before blaming something new. The
   netavark errors looked damning until they turned up in the morning's working
   runs too.
5. **State what is established vs claimed.** `docs/phase2-debug-plan.md` keeps
   these separate deliberately.

## 10. Process

- **One deployer/initramfs change per run.** Every change costs 60–90 minutes;
  batching makes attribution guesswork. Three times a "fix" was applied to
  something that was not broken while introducing something that was.
- **A fix for an observability gap is not free.** The `/dev/console` change was
  meant only to make failures visible and it stalled every deploy.
- **Put the reasoning in the test, not just the commit.** Tests here carry the
  failure they prevent, so the next person cannot "simplify" it away.
- **Retention matters.** Each run writes ~3 GiB of artifacts and needs ~45 GiB
  resident. Without pruning, a successful run breaks the next one.

## 11. Current known-bad hosts

| Host | Issue |
|---|---|
| kanpur | podman resolves root storage under `systemd-run --user` (#41); runs die without a `[FAIL]` line |
| dilli | container QEMU lost KVM after `podman system migrate` (#42); 238 GiB disk is undersized for a ~45 GiB/run workload |
| himachal | healthiest of the three; 952 GiB |

Prefer `e2e-hosted.yml` on ubuntu-latest over all of them.

---

# Part 2 — the Phase-2 hunt (2026-07-19)

The first half of this document was written mid-session. What follows is what
the rest of the day taught, including six regressions I introduced myself.
Read §12 first; it is the one that would have saved the most time.

## 12. Get inside a live box. Do not wait for the run to finish.

The single highest-value technique of the entire session, and it came from the
user telling me to stop waiting.

Four consecutive 90-minute runs failed without producing an attributable cause.
Then one command answered it:

```sh
podman exec <container> python3 /tmp/qga.py powershell '$env:OS'
# -> Windows_NT   ... while the harness was 61 minutes into "Deploying..."
```

The guest was not running the deployer at all. From there, two minutes of live
inspection found what four runs had not:

```sh
# which OS is actually running?
qga.py exec /bin/sh -c "uname -sr"
# what is the process actually doing?
qga.py exec /bin/sh -c "ps -eo pid,ppid,stat,wchan:20,args"
# what did it last say? (the deployer's own journal, live)
qga.py exec /bin/sh -c "journalctl --no-pager | grep -a wootc | tail -20"
```

`wchan` is the key column: `do_wait` means blocked on a child,
`hrtimer_nanosleep` means a sleep, `anon_pipe_read` means blocked on a pipe.

**Post-hoc artifacts repeatedly failed** where live inspection worked: the
deployer log could not be read because the guest was in an emergency shell, and
the journal artifact came back at 111 bytes. If a VM is hung, go in NOW — the
evidence disappears when the run cleans up.

The deployer initramfs ships `qemu-ga`, so this works during Phase 1 too, not
just once Windows is back.

## 13. Phase 2 was never *failing*. It was never *reachable*.

Worth internalising as a class of mistake, not just a fact.

For most of the session I debugged Phase 2 as though it were broken: the attach
hook, the qemu-nbd closure, the NTFS driver, hypotheses A1–A6. All of it was
reasoning about components **that were never installed**, because the deploy
died before staging them.

The proof took one manual boot: force the BCD one-shot by hand and look at the
GRUB menu.

```
*Install wootc (automatic)
 Install wootc (debug)
```

No entry for the installed system — while `root.vhdx` held a complete 6.6 GB
ostree deployment. The OS was installed and unreachable.

**Lesson:** before debugging why a stage fails, verify the stage can be entered
at all. One QGA call would have shown this on day one.

## 14. A watchdog you have to signal is a bug factory

Three designs, two of which I made worse:

1. `( sleep 2700; force_reboot ) &` — never cancelled. `dracut-initqueue`
   blocked in `wait()` for the full 45 minutes after the deployer returned, so
   Phase-2 setup never ran and the exit status was never printed.
2. Added `kill "$pid"; wait "$pid"`. When the kill misses, that `wait` blocks
   **forever** — a permanent hang replacing a 45-minute one.
3. Wrapped the sleep in `setsid` so it could not outlive its subshell. That put
   it in its own **session**, beyond the reach of both the pid kill and the
   process-**group** kill. Strictly worse. Confirmed live:

   ```
   453  1    S   do_wait            /usr/bin/sh /usr/bin/dracut-initqueue
   455  453  Ss  hrtimer_nanosleep  sleep 2700     <- Ss = session leader
   ```

The working design signals nothing: the watchdog polls a flag file, cancelling
is `: > /run/wootc-deploy-done`, and the loop exits within one tick by itself.

**Generalisation:** in a shell, prefer a background task that *observes a
condition and exits* over one you must find and kill. `wait` on a pid you do not
control is an unbounded block; `kill` is unreliable the moment process groups or
sessions are involved.

## 15. Things that match themselves

Three variants bit in one day. All produce confident, wrong answers.

- **`pgrep -f "run-e2e.sh"` over ssh** matches the ssh command running it.
  Reported dead runs as alive.
- **Polling `journalctl | grep verify:`** logs *your own command*, which then
  matches the grep. The output was entirely my own polling.
- **A test grepping for a string that appears in its own comment.** Happened
  three times: a preflight guard matched the comment quoting the error, and a
  `setsid` removal test matched the comment explaining the removal.

Rule: when grepping for a pattern, exclude the searcher. `grep -v qemu-ga`,
`grep -v $$`, `grep -nE '^[^#]*pattern'`.

## 16. My regression rate, and its cause

Six regressions introduced while fixing things, in one session:

| # | Change | Damage |
|---|---|---|
| 1 | `podman system prune -af` on live hosts | killed 3 runs; deleted the built ssh image |
| 2 | triple `/dev/console` logging | saturated serial, stalled every deploy |
| 3 | folding kernel reboot into DEPLOYER_REBOOT_SEEN | false `[PASS]` on a dead deploy |
| 4 | `kill` + `wait` in cancel_watchdog | permanent hang |
| 5 | `setsid` on the watchdog sleep | made it uncancellable |
| 6 | RunId barrier without refreshing C:\OEM | mutual deadlock, guest timed out |

The cause is single and structural: **I changed code faster than a 20–90 minute
feedback loop could validate it.** Every one of these looked correct when
written and was wrong in an interaction I could not test locally.

Mitigations that actually work, in order of value:
1. **Reproduce in a container first.** The qemu-nbd closure was diagnosed AND
   its fix verified in a container in minutes.
2. **One deployer change per run.** Repeatedly violated under pressure to show
   progress; every violation cost more than it saved.
3. **Round-robin the runners** (§17) so a fix is validated sooner.
4. **Prefer designs that cannot fail the same way** — the flag-file watchdog
   over any amount of careful signalling.

## 17. Round-robin the fleet

With three runners staggered by ~15 minutes, a fix is validated against whichever
reaches the interesting stage first, instead of waiting a whole cycle. It also
supplies what #34 needs (a pass RATE at one commit) and covers "multiple cases".

Launch notes per host are in AGENTS.md. kanpur needs `nohup` rather than
`systemd-run` (#41); all hosts need `loginctl enable-linger`.

## 18. Reuse the helper that already exists

I wrote an ad-hoc loop to push files into the guest, using `$OEM_DIR` — a HOST
path — while `qga.py` runs inside the container and sees that mount at `/oem`.
Every write failed. `qga_sync_oem()` already existed forty lines away, did it
correctly, and was merely gated on `--skip-install`.

Before writing a helper, grep for one. Before passing a path to something that
runs in a container, ask whose filesystem that path is on.

## 19. Guest/host state must be refreshed, not assumed

`C:\OEM` is populated from the ISO at Windows install time. Any guest whose
Windows was installed by an earlier run carries THAT run's scripts. Introducing a
protocol change (the RunId barrier) without refreshing the guest deadlocked both
sides: the guest stamped an old constant, the host never matched, and each waited
on the other until the guest's 10-minute deadline expired.

If you change a host/guest protocol, push the guest half of it in the same
change.

## 20. A retried command is a second command

`qga_call` retries three times to survive flaky agents. Sent through a boot
transition, the retry is poison: a `systemctl reboot` the dying guest never
consumed sat in the virtio-serial channel until the NEXT agent opened it — the
freshly booted native install, which obeyed and rebooted straight back to
Windows (BootNext one-shot, already consumed). Earlier runs "survived" only
because guest-exec was still blacklisted natively; fixing the blacklist armed
the trap.

Side-effecting commands must never ride a retried channel across a boot
boundary. Use the QEMU monitor (`system_reset`) — it queues nothing anywhere.
And remember any single reboot of the native system lands in Windows: BootNext
fires once, BootOrder still lists Windows first.

## 21. A service that can succeed while doing nothing is unobservable

`wootc-mount-user-dirs` exited 0 with zero binds and an empty journal — each
profile was skipped by a silent `continue`. The condition it skipped on
(`[[ -d $home ]]`) was itself a deployment bug: fisherman's
`useradd --create-home` followed the deployment's `/home -> var/home` symlink
into the deployment's OWN var, which the stateroot var mount masks at runtime.
Two rules: every skip on an "impossible" condition logs an ERROR naming the
bug, and every unit that can no-op logs a final summary line
("N binds across M users") so the journal alone convicts or acquits it.

## 22. Forensics beat theorizing: the disks were all still there

The failed run's whole story was recoverable offline: `qemu-nbd` the graduated
qcow2 → native journal showed the exact reboot command and its source pid;
loop-mount root.disk inside the NTFS qcow2 → the orphaned home in the
deployment's masked var. Two dead ends to skip next time: a `qemu-nbd
--connect` dies with its ssh session (do all reads in ONE session, or it reads
as a corrupt/empty GPT with fresh random GUIDs per call), and the serial pty
spans every boot of the run — sed from the FIRST "GRUB version" banner lands
in Phase-1, not the boot you care about (anchor on `BdsDxe: starting BootNNNN`
line numbers instead).

## 23. `--root` is not chroot

`useradd --root <dir>` chroots — after initializing the HOST's PAM/SELinux
stack. From the deployer initramfs it worked for months; from booted Phase 2
it failed with "failure while writing changes to /etc/passwd" against an etc
that append/touch proved writable. `chroot <dir> useradd` succeeded on the
same files, same second. Offline user tooling must run the TARGET's binaries
via plain chroot; the flag that looks equivalent is environment-sensitive in
exactly the way an initramfs test bed cannot reveal.

The debugging move that cracked it in minutes: while the failed Phase 2 was
still running, reproduce the exact failing command by hand over QGA, then
bisect the variants (--root vs chroot vs --prefix) live. One boot's evidence
beats three relaunch cycles.

## 24. A verdict is only trustworthy if the run actually ended

`run-matrix.sh` polled for any `[FAIL]` line and concluded on the first one.
But several run-e2e checks are invoked as `... || true`, so a **non-fatal**
failure line looks identical in the log to a fatal one. A cosmetic
`seed_user_data` failure therefore ended the poll ~35 minutes early, recorded
itself as the case's verdict, and sent me hunting a "composefs" bug that was
neither composefs nor the reason the case died — while the run was still
deploying.

The rule: conclude on a **terminal state**, never on the presence of a scary
line. `run-e2e.sh` stamps `stage=exited` from an EXIT trap, so an ending is
always observable; the last `[FAIL]` then supplies the *reason* — it does not
supply the *fact* of failure. And delete the previous case's state file with
its log, or a stale stamp declares the new case finished the moment it starts.

This is lesson §21's sibling: there, a service could succeed while doing
nothing; here, an observer could report a failure that had not happened yet.

## 25. The guest chooses the drive letter, not you

On the BitLocker axis `setup-wootc.ps1` carves an unencrypted volume and puts
the whole tree on it — `E:\wootc\{disks,install,logs}`. The harness hardcoded
`C:\wootc\...` in four places. So `el10-gnome-win11pro-bitlocker` deployed
**successfully**, passed both FDE assertions (C: still encrypted, Linux on
unencrypted E:), and then died 39 minutes in on "Could not read wootc BCD GUID
from Windows" — reading a file from a drive it was never written to. The VDL
extension had already silently skipped for the same reason, reporting only
`size='0'` at INFO level.

Two habits fall out of this:
- When the guest-side script computes a location (`$storageRoot`), the
  host-side must **ask for it**, not re-derive it. `guest_wootc_root()` queries
  the guest and caches only a positive answer.
- `info "Could not read X (size='0'), continuing"` is a bug report wearing a
  progress message. A read that returns nothing where something must exist is
  never a continue-quietly condition.

## 26. `podman build` blames your Containerfile for the runtime's crash

A GUI E2E died at 6 minutes with what read as a broken package list:

```
Error: building at STEP "RUN dnf install -y  systemd systemd-udev ...": while running runtime: exit status 1
[FAIL] Deployer build failed
```

Nothing was wrong with the packages. Two lines up, unhighlighted, was the real
event: `error running container: from /usr/bin/crun creating container` /
`did not get container create message from subprocess: EOF`. The container was
never created, so `dnf` never ran — but the error names the RUN step, so the
instinct is to go read the package list.

The cause was a hosted runner-image bump: podman 4.9.3 → 5.8.4 with
`/usr/bin/crun` left at 1.14.1. Podman 5 emits an OCI spec version crun 1.14
rejects (`crun: unknown version specified`). Note the *good* error text exists —
it appears verbatim in `podman run`, and it was `podman build` that buried it.

Three habits:
- **Check the blast radius before diagnosing.** The same push turned the
  container test suite red, and *that* log printed the unswallowed
  `crun: unknown version specified`. A failure appearing in two unrelated
  workflows is environmental; one that appears in only one is yours. This is
  what turned a wrong guess (AppArmor userns restrictions — the other cause of
  `EOF` at create) into the actual answer in one step.
- **`crun --version` does not tell you what podman runs.** Hosted runners carry
  more than one crun; `$PATH` prefers `/usr/local/bin` while podman prefers
  `/usr/bin`. A bare `crun --version` reported 1.28 before *and* after
  installing 1.28, which nearly credited the fix to an unrelated image patch.
  Ask the engine: `podman info --format '{{.Host.OCIRuntime.Path}} {{.Host.OCIRuntime.Version}}'`.
  For the same reason `.github/actions/podman-runtime` installs over
  `/usr/bin/crun` — a `/usr/local/bin` copy is on `$PATH` but invisible to podman.
- **The hosted pool is mixed.** Jobs in the same run landed on podman 4.9.3 and
  5.8.4, so an environment repair must be unconditional and then *verified by a
  real `podman run`*, not gated on a version comparison. Version strings are a
  proxy; a container that starts is the fact.

## 27. Rebooting is not releasing. Phase 2 owed Windows a clean unmount.

Both `fedora-gnome` cells of run 30704513401 failed identically — so, not a
flake — with `[FAIL] QGA did not become available for Windows return after
Phase 2 Linux within 10 minutes`. Phase 2 itself was flawless: it booted,
passed every passthrough and user-data check, and rebooted on cue. The damage
was done on the way out, and it was visible in five lines of serial nobody had
been reading:

```
(sd-remount)[...]: Failed to remount '/run/initramfs/wootc-host' read-only: Device or resource busy
systemd-shutdown[1]: Not all file systems unmounted, 1 left.
systemd-shutdown[1]: Not all loop devices detached, 1 left.
systemd-shutdown[1]: Cannot finalize remaining file systems, loop devices, continuing.
reboot: machine restart
```

Windows then showed a desktop for ~26 s, rebooted itself, looped the boot
manager three or four times and died in Startup Repair. The QGA timeout was a
*symptom four reboots downstream* of the actual bug.

- **A boot stack that lives on the thing it must release cannot release it.**
  Phase-2 `/` is a loop device backed by `root.disk`, a file on the rw NTFS
  mount. Nothing running inside that stack can unmount the volume. The
  deployer already knew this — `deploy.sh` has a whole block ending "a
  still-mounted rw NTFS would be flagged dirty" — and Phase 2 simply never got
  the same treatment. **When one side of a symmetric operation has a hard-won
  teardown, go look for the other side.**
- **A missing file can disable an entire subsystem in total silence.**
  `dracut-shutdown.service` populates `/run/initramfs` from
  `/boot/initramfs-$(uname -r).img`. On ostree/composefs that path does not
  exist, `dracut-initramfs-restore` no-ops, and systemd — which only pivots
  when `/run/initramfs/shutdown` is executable — quietly skips the whole
  shutdown-initramfs mechanism. No error, no warning, and the *absence* of
  "Returning to initrd..." in the log is the only tell.
- **Corruption sorts by driver, and the passing cells were the clue.** Every
  cell mounting the host volume with kernel `ntfs3` failed; every cell that
  fell back to the `ntfs-3g` FUSE driver passed. That correlation is what
  turned "flaky Fedora cell" into "structural teardown bug" — a green cell is
  evidence too, and diffing it against the red one costs minutes.
- **Make the dangerous new path revert to the old one.** The fix arms a
  shutdown pivot that did not previously happen, on every cell's boot path,
  and cannot be tested outside a 60–90 minute VM run. So every failure path in
  the staging hook ends by deleting `/run/initramfs/shutdown` — without it
  systemd does not pivot, which is *exactly* today's behaviour. A partial or
  broken staging can only reproduce the bug it is fixing; it cannot invent a
  new one.

## 28. The initramfs is not your laptop, and `[FAIL]` is not a log level

`bluefin-dakota-win11pro` (run 30707067821) died 11 minutes into the deploy on
two lines:

```
[wootc] ABORT: line 1281: awk '{for(i=1;i<=NF;i++) if ($i ~ /^\//) print $i}' (exit 127)
[FAIL] qga: ldd on the deployer's qemu-ga surfaced no dynamic loader
```

- **A dracut initramfs contains exactly what `module-setup.sh` names.** Every
  closure builder in `deploy.sh` resolved libraries with `ldd "$bin" | awk …`.
  `ldd` is a glibc-common *shell script*; no library dependency drags it in,
  nothing listed it, so it was never in the image. Reach for the thing whose
  presence is structurally guaranteed instead: the dynamic loader has to be
  there or the deployer itself could not run, and `$ldso --list` is what `ldd`
  execs anyway. `dso_closure()` now does that in pure bash, so no missing text
  tool can break a closure either.
- **Exit 127 names the wrong command.** Under `set -o pipefail` the ERR trap
  reported the `awk` stage of a pipeline whose *first* stage was the missing
  one. When a trap blames a command that obviously exists, suspect the rest of
  the pipeline before you suspect the trap.
- **`[FAIL]` on the deployer serial is an API, not a severity.** `run-e2e.sh`
  greps the serial for `fatal|panic|[FAIL]` and ends the deploy on the first
  hit. The qga stager printed `[FAIL]` for a condition its own caller absorbs
  with `[WARN] no fallback qemu-ga staged` — so a survivable best-effort miss
  killed a cell that was otherwise fine. A function may only shout `[FAIL]` if
  every one of its callers treats the failure as fatal.
- **The same rule bites the harness.** `run-e2e.sh` also printed
  `[FAIL] run-e2e.sh aborted: awk …` on every hosted cell, because `-E`
  propagates the ERR trap into the command substitution probing for a
  `tailscale0` that hosted runners do not have. Nothing aborted. The matrix
  takes the *last* `[FAIL]` as the verdict, so an optional probe was one silent
  timeout away from becoming a run's official cause of death.
