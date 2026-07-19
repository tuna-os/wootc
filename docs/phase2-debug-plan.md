# Phase-2 debug plan and open hypotheses

Status as of 2026-07-18. Written after four consecutive failed E2E runs, none of
which produced enough evidence to attribute the failure.

## What we actually know

Stated precisely, because this session has already burned time on three
confidently-wrong root causes (ntfs-3g injection, the multi-disk hypothesis, and
"the deploy wait has no timeout").

**Established:**

- Phase 1 works end to end on kanpur. Serial shows `wootc: deployer active`, a
  19-minute deploy, `deployer requested reboot`, Windows QGA returning, and the
  BCD one-shot scheduled *with bootsequence verified*.
- kanpur and himachal both fail Phase 2 identically: emergency shell,
  `sysroot.mount` dependency failed, `/dev/disk/by-uuid/<root>` absent.
- dilli fails **differently**. Its serial ends at
  `BdsDxe: starting Boot0003 "Windows Boot Manager" ... bootmgfw.efi`.
  Firmware went straight back to Windows; Phase 2 was never attempted.
- The staged payload is complete and correct on disk (`shimx64.efi`,
  `grubx64.efi`, deployer kernel + initramfs, `root.vhdx`).
- `ntfs-3g` injection into the target image **fails outright**
  (`[WARN] ntfs-3g install failed ... relying on the image's own NTFS support`).

**NOT established, despite earlier claims:**

- That Phase 2 has *ever* booted. Every prior "rung-2 GREEN" predates the
  proof-of-life gate (`d92c279`) and was not conditioned on any observable.
- What actually mounts NTFS in Phase 2 (#35).
- Whether the loop-attach hook is present in the Phase-2 initramfs.

## Why we could not tell

Three independent observability defects, all now fixed. They are listed because
the pattern matters more than the individual bugs: **every one was optimistic
status not grounded in an observable.**

| Defect | Effect | Fix |
|---|---|---|
| `info()`/`warn()` filtered by printk | hook diagnostics never reached serial | `93e87e1` — write to `/dev/console` |
| `ELAPSED` counted sleeps, not wall-clock | timeouts ~1.5× nominal; misreported minutes | `bc504a1` — wall-clock deadlines |
| `snapshot_serial` failed silently | harness read a frozen serial file for 2h | `aa00b24` — fail loudly, drop stale copies |
| Phase-2 boot checks were advisory | `ALL TESTS PASSED` for a boot that never happened | `d92c279` — proof-of-life gate |

## Hypotheses

### Branch A — kanpur/himachal: reaches Phase 2, no root device

Ordered by my estimated likelihood. Each is stated so the next run's serial
output discriminates it, because the instrumented hook now announces entry and
names a reason at every exit.

**A1. Hook present but exits at the karg check.** The BLS entry or `grub.cfg`
did not carry `loop=` / `wootc.host_uuid=`. `deploy.sh:616` edits loader entries
with `sed`; if the entry format differs or the edit silently no-ops, the hook
runs and immediately returns.
→ *Discriminator:* `EXIT: missing kernel args (loop='' wootc.host_uuid='')`.

**A2. Host NTFS will not mount.** *Demoted.* Confirmed the target image has no
`ntfs-3g` binary, so the FUSE fallback cannot work — the kernel `ntfs3` driver
is the only candidate.

⚠️ **Caveat, do not repeat the earlier mistake.** Probing `/proc/filesystems`
inside `podman run` reports the **host's** running kernel, *not* the image's.
So the `ntfs3` line observed that way is **not** evidence that the image's own
kernel has NTFS support. This is the same class of error that produced the wrong
"EL10 lacks NTFS → inject ntfs-3g" root cause. The only trustworthy evidence is
the hook's own runtime probe, which is now printed on the `EXIT:` line.

→ *Discriminator:* `EXIT: cannot mount host NTFS rw ...` with the `ntfs3=` and
`ntfs-3g=` counts, measured inside the actual Phase-2 initramfs.

**A3. `qemu-nbd` attach fails.** *Promoted to most likely* on 2026-07-18.

The target image `ghcr.io/tuna-os/yellowfin:gnome` **does not contain
`qemu-nbd`** (verified: `command -v qemu-nbd` → not found). The Phase-2 hook
calls it unconditionally, so the binary must come from the initramfs.

It is staged by a cross-image copy: `deploy.sh:618` does
`install -m755 "$(command -v qemu-nbd)" .../99wootc-boot/qemu-nbd`, taking the
binary from the **deployer's** environment, and `module-setup.sh:28` then
`inst`s it into an initramfs built from the **target** image. That is a
dynamically-linked binary crossing image boundaries: its `glibc` and library
dependencies come from the deployer, but the initramfs is assembled from the
target's libraries. A version skew there yields a binary that is present but
cannot execute — which fails exactly like a missing one, silently, at the last
step before the root device would appear.

Two sub-cases worth separating:
- **A3a** binary absent from the initramfs (staging or `inst` failed);
- **A3b** binary present but unable to run (missing/mismatched shared libs).

→ *Discriminator:* `EXIT: qemu-nbd failed to attach ...`, which now also prints
whether the binary resolves and whether the `nbd` module is loaded. A3b
specifically needs `ldd`-style evidence — see step 2b of the plan.

**A4. Attach succeeds but the root UUID never appears to udev.** Partition scan
did not happen, or the UUID in the BLS entry does not match what is inside the
VHDX. This is the one that would look most like "hook worked fine" — which is
exactly why the hook now prints post-attach partitions and `by-uuid` contents.
→ *Discriminator:* attach success followed by a `post-attach by-uuid` list that
lacks the expected root UUID.

**A5. Race: the UUID appears after `sysroot.mount` has already given up.**
`rd.timeout=120` is set, so this is unlikely, but an initqueue/settled hook that
only fires late could still lose.
→ *Discriminator:* attach success and a correct `by-uuid` list, yet still
emergency — i.e. all hook output looks healthy.

**A6. Hook absent from the Phase-2 initramfs.** `deploy.sh:698` has a guard that
aborts the deploy if `lsinitrd` cannot find the hook, and kanpur's deploy did
*not* abort — but the guard is conditional on `INITRD_CHROOT_PATH` being set and
`lsinitrd` existing, and otherwise only logs `[WARN]`. Deploy logging now reaches
serial, so the guard's own verdict will be visible.
→ *Discriminator:* no `attach-loop hook entered` line at all, plus the deploy's
`guard: lsinitrd listed N entries` line.

### Branch B — dilli: BCD one-shot did not take

**B1. One-shot consumed by an earlier boot.** `bootsequence` is one-shot by
design; anything that boots between staging and the intended Phase-2 boot eats
it, and the next boot goes to Windows.

**B2. Secure Boot rejected the chain.** shim or GRUB failed validation and
firmware fell through to the next entry silently. The Fedora grub prefix and
embedded-module work is the relevant history here.

**B3. Firmware ignored `bootsequence`.** Some firmware honours `BootNext` but
not the BCD-level one-shot; dockur's OVMF may differ from the laptops'.

Branch B has the weakest evidence — one frozen serial log, n=1. It should not
be theorised about further until a run reproduces it with live serial.

## The plan

**Do exactly one Phase-2 run and read it.** No code changes to the boot chain
first. The point of the last four commits is that a single run should now
produce an attributable answer; spending that run is cheaper than any further
reasoning from the current evidence.

1. **One run on kanpur** (Phase 1 is proven there; it isolates Branch A).
   Read: does `attach-loop hook entered` appear? If yes, which `EXIT:` line? If
   no exit line, what do `post-attach partitions` / `by-uuid` show?
2. **Attribute to a single hypothesis** above. Do not fix anything until the
   serial names which one.

   **2b. Cheap check that can be done BEFORE spending a run** (and should be,
   since A3 is now the leading hypothesis): unpack a deployed Phase-2 initramfs
   and confirm (i) `/usr/bin/qemu-nbd` is present, and (ii) every shared library
   it needs is also in the image. `lsinitrd <img> | grep qemu-nbd` answers A3a;
   comparing its `NEEDED` entries against the initramfs contents answers A3b.
   This costs minutes rather than a ~1 hour VM run, and if it comes back
   negative it explains kanpur and himachal outright.
3. **Then, and only then, fix.** Each branch has a different fix and they are
   not compatible — A1 is a `sed`/BLS problem, A2 is an image-content problem,
   A3/A4 are a VHDX/udev problem.
4. **Separately, one run on dilli** to see whether B reproduces with a live
   serial feed. If it does not reproduce, close it as a one-off.
5. **Establish a pass rate before believing anything is fixed** (#34). N runs at
   one commit, not one green run. A single pass is what produced the false
   confidence in the first place.

**Explicitly deferred:** the raw-vs-VHDX question (#39). If the hook reports a
successful attach, VHDX corruption is not our problem and the whole question is
moot. Deciding it now would be reasoning ahead of evidence.

## Standing rule this came from

Every failure this session was invisible before it was wrong. The recurring bug
class is *status derived from a timer or an assumption rather than from an
observable*. When adding any check, ask: what does this assert, and what would
it print if the thing it asserts never happened?

---

# Reflection: why the failure rate went up (2026-07-19)

## First, a reframe: Phase 2 is not failing more — we stopped reaching it

Worth stating plainly because it changes what to investigate. Phase 2 was
reached exactly twice, both early on 2026-07-18 (kanpur, himachal), and both
dropped to an emergency shell. **Since then, not one run has reached Phase 2 at
all.** Every failure since has been Phase 1 or infrastructure:

| Failure | Cause | Mine? |
|---|---|---|
| 3 runs killed mid-flight | `podman system prune -af` on live hosts | yes |
| deploys stalled at `phase: verification` | triple `/dev/console` write saturating serial | yes |
| runs died ~10min after launch | no systemd linger; ssh session teardown | partly |
| deploys timed out at 45m | wall-clock fix made the budget honest, exposing it as too small | yes (consequence) |
| preflight disk failures | no artifact retention; ~60 GiB resident per run | pre-existing |
| kanpur build failures | host podman/unit config drift | no |

So the increase is overwhelmingly **my churn**, not a product regression. The two
genuine product findings (qemu-nbd library mismatch, BitLocker VHDX placement)
still stand and are unaffected.

## The snapshot hypothesis is well-founded

`snapshot_before_deployer()` does this:

1. `qga_call freeze` — fsfreeze the Windows filesystems (via VSS on Windows);
2. copy `data.qcow2` (18–28 GiB) to `.snap` **while the guest stays frozen** —
   the code comment says "the guest stays frozen until the copy is complete";
3. `qga_call thaw`.

Two things make that dangerous, and both are now confirmed by observation:

**`cp --reflink=always` FAILS on these runners.** We see
`cp: failed to clone ...` on every host, so it falls through to
`--reflink=never` — a full byte copy of 18–28 GiB. That is 10–20+ minutes, not
the instant CoW clone the design assumed. The freeze window was sized for a
reflink.

**Windows VSS cannot hold a freeze that long.** VSS imposes hard limits (writers
~10s, overall ~60s). A 20-minute freeze is not something the guest will honour;
it will auto-thaw or fail the snapshot mid-copy. So:

- the resulting `.snap` is **not** crash-consistent, contrary to the comment;
- more importantly, the guest experiences a long freeze and an abrupt
  timeout-driven thaw under heavy host I/O contention.

**The link to Phase 2:** an NTFS volume that was frozen and abruptly thawed can
be left with the dirty bit set. A dirty NTFS **cannot be mounted read-write by
ntfs3** — which is exactly the Phase-2 failure we saw, and exactly what the
attach hook's own warning says:

    wootc: cannot mount host NTFS rw (no ntfs3 and no ntfs-3g).
    Dirty volume? Boot Windows once and full-shutdown; ...

That is a coherent mechanism from snapshot → dirty NTFS → `root.disk never
attached` → emergency shell. It is a hypothesis, not a proven cause, but it is
the best-supported explanation of the two Phase-2 failures we have.

## And the snapshot is never used

`data.qcow2.snap` is written and **never read**: the only reference in
run-e2e.sh is inside `snapshot_before_deployer()` itself. There is no restore
path. So today it costs:

- a 10–20 minute freeze of the guest at a delicate moment,
- ~28 GiB of disk (the direct cause of the preflight failures),
- a large slice of the deploy budget,

in exchange for an artifact nothing consumes.

**Recommendation: disable it by default.** Not "optimise" — remove from the
default path, behind `WOOTC_E2E_SNAPSHOT=1` for when a restore path exists. This
is the single highest-value change available: it removes the most plausible
cause of the Phase-2 NTFS failure, frees ~28 GiB, and shortens every run.

## The process failure, honestly

The deeper problem is not any single bug — it is that **there is no fast feedback
loop for deployer/initramfs changes**. Every change costs a 60–90 minute VM run,
so I batched several changes per run cycle. When a run then failed, attribution
was guesswork, and three times I "fixed" something that was not broken while
introducing something that was.

Rules to work by from here:

1. **One deployer change per run.** If two need testing, run twice.
2. **Prefer changes testable without a VM.** The qemu-nbd closure was diagnosed
   and verified in a container in minutes — that is the model.
3. **Never touch a host with a live run** (prune, kill, disk cleanup).
4. **A fix for an observability gap is not free.** The `/dev/console` change was
   meant only to make failures visible and it stalled every deploy.
5. **Verify the observable, not the exit code.** `pgrep` matching my own ssh
   command reported runs as alive that did not exist.

## Outstanding risk I introduced and have not tested

The Phase-2 attach hook still writes to `/dev/console`. That is the same call
that stalled `deploy.sh` — kept here because volume is far lower (a handful of
lines at boot vs hundreds during an install). But the failure mode was a
*blocking* write, and volume only changes its likelihood, not its possibility.
If Phase 2 hangs with the hook's first line printed and nothing after, this is
the first suspect.
