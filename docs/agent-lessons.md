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
