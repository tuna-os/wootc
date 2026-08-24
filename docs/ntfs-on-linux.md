# NTFS on Linux: the known problems, and why wootc survives them

NTFS support on Linux has a deserved reputation for sharp edges. wootc's
entire design lives *next to* NTFS — the Linux system is a file on the
Windows C: drive — so "are we subject to those issues?" deserves a precise
answer, not reassurance.

The honest answer: **we are exposed to NTFS-on-Linux at four narrow choke
points, and the design is built so that none of them can decide the
integrity of the Linux system or of Windows.** One of these hazards has
already bitten a real run; the fix and its regression test are part of the
story below. Every claim here is tied to the code that enforces it.

## The problems, as they actually exist

1. **NTFS cannot host a Linux system.** No POSIX permissions (uid/gid are
   faked at mount time), no security xattrs (so no SELinux labels), no
   case sensitivity, symlinks only as reparse points. A Linux root placed
   directly on NTFS is broken from first boot.
2. **Two drivers, different failure modes.** The kernel `ntfs3` driver
   (Paragon, merged in 5.15) is fast but young — it has shipped
   corruption and sparse-file bugs, went through unmaintained stretches,
   and refuses volumes the older driver accepts. The FUSE `ntfs-3g`
   driver is slow but battle-tested since 2007. Distributions disagree
   about which one you get, and some images ship neither.
3. **Dirty volumes, hibernation, and Fast Startup.** Windows Fast Startup
   is hibernation in disguise: "shut down" leaves the filesystem
   journaled-open with metadata cached inside `hiberfil.sys`. Mounting
   that volume read-write from Linux is the classic dual-boot data-loss
   story, and `ntfs3` refuses dirty volumes even read-only.
4. **Valid Data Length (VDL).** NTFS tracks how much of a file's
   allocation has actually been written. The Linux `ntfs3` driver EIOs on
   writes past VDL — a Windows-side subtlety invisible until a loop
   device dies mid-write.
5. **Only Windows can repair NTFS.** Journal replay and `chkdsk` are
   Windows facilities; `ntfsfix` clears flags, it does not fix
   filesystems. Anything Linux corrupts, only Windows can heal.
6. **Unmount discipline is on you.** A Linux mount that is not cleanly
   released leaves the volume dirty for the next Windows boot.

## The design answer, hazard by hazard

### Linux never lives *on* NTFS — NTFS only stores a container's bytes

The installed system's root is **inside `root.disk`**, whose *contents*
are a real Linux filesystem (xfs, ext4, or btrfs) with full POSIX
permissions, security xattrs, and SELinux labels. NTFS's job is reduced to
storing one large file's bytes; none of its semantic gaps (problem 1) can
reach the OS. This is the load-bearing decision — everything else follows
from it. (`app/disk_windows.go`, `docs/philosophy.md` on the Wubi
heritage.)

### Windows allocates; Linux writes inside the lines

`root.disk` is created **by Windows, with Windows' own NTFS driver**:
sparse allocation via `SetLength`, then the Valid Data Length is extended
with `fsutil file setvaliddata` — precisely because the Linux `ntfs3`
driver EIOs on loop-device writes past VDL (problem 4; the comment above
`createRootDisk` in `app/disk_windows.go` records this). Linux never asks
an NTFS driver to make allocation decisions; it performs bulk I/O within a
file whose NTFS metadata Windows already settled. Host-profile bind mounts
use `ntfs3`'s `prealloc` option for the same reason.

### Fast Startup is removed at the source, and put back on the way out

The install preflight detects both halves separately — the
`HiberbootEnabled` registry flag *and* a hibernation image actually on
disk (`app/sysprobe_windows.go`; the distinction mattered, see #63). The
install then runs `powercfg /h off` **and** clears `HiberbootEnabled`, so
every "shut down" from that point is a full shutdown and the volume Linux
mounts is journaled-closed (problem 3). Uninstall restores the user's
prior power state (`restorePriorPowerState`) — "Windows is unchanged"
stays true after leaving.

Defense in depth: the deployer still treats dirty volumes as possible.
Its read-only scan mounts try `ntfs3 -o ro`, then `ro,force`, then
`ntfs-3g` (`payload/deployer/deploy.sh`), and the Phase-2 attach hook's
failure message names the fix a user can actually perform: "Boot Windows
once and full-shutdown."

### No single driver is trusted — a probe chain decides at boot

The Phase-2 attach hook (`platform/dracut/99wootc-boot/wootc-attach-loop.sh`)
probes in order: kernel `ntfs3` (which may be built in, with no `.ko` to
find), then the `ntfs-3g`/`lowntfs-3g` FUSE drivers, then the legacy
`ntfs` type — because image support genuinely varies (problem 2). The
deployer ships its **own** self-contained `ntfs-3g` closure
(`stage_ntfs3g_closure`: binary, full library closure, and loader, proven
by execution) so an image that ships no NTFS driver at all still attaches.
Which driver won is printed to the serial console and asserted by the E2E
per image — the proven combinations are in `docs/status.md`, not in a
promise.

### One writer at a time, by construction

Windows and Linux never touch the volume concurrently: Phase 2 boots only
after Windows has fully shut down, and Windows returns only after Phase 2
has rebooted. Mutual exclusion is enforced by the machine itself — there
is no file-locking protocol to get wrong.

### The volume is handed back *closed* — the hazard that actually bit

Problem 6 is not hypothetical here. Phase 2's root is a loop device backed
by a file on the rw NTFS mount, so at shutdown the stack pins itself:
systemd could not remount the NTFS read-only, Windows booted into a
half-open volume, looped the boot manager, and died in Startup Repair
(run 30704513401 — notably, **only the kernel-`ntfs3` cells** failed;
FUSE cells survived, which made a structural bug look image-specific).
The fix pivots PID 1 back into the initramfs at shutdown
(`/run/initramfs/shutdown`), where the root is no longer the loop device,
so the loop detaches and the NTFS unmounts cleanly — including on ostree
and composefs images where dracut's normal restore path no-ops. The full
story is `docs/phase2-attach-postmortem.md`; the contract is pinned by
`tests/unit/phase2-clean-ntfs-umount.bats`, and the E2E asserts Windows
actually comes back after every Phase-2 run.

### Blast radius: a container file, never the C: volume

The worst realistic outcome of an NTFS-driver bug on our write path is
damage *inside* `root.disk` — the user's Linux, recoverable by
reinstalling into the same file, while Windows and the user's files are
untouched. The reverse worry (Linux damaging C: metadata) is bounded by
the facts above: Windows performed the allocation, writes are
within-file, mounts are exclusive and cleanly released, and `chkdsk`
retains a healthy volume it fully owns. And the exit is always one
deletion away: remove `root.disk`, and NTFS never knew we were there
(`docs/user-guide.md` §9 — the uninstall's cleanup claims are themselves
E2E-verified).

## What we deliberately do not do

- **No Linux root directly on NTFS.** Ever. That design fails problem 1
  on day one.
- **No writing to a hibernated volume.** Fast Startup is disabled before
  the first byte is staged, not worked around afterward.
- **No betting on one driver.** Both `ntfs3` and `ntfs-3g` are first-class
  paths, per image, chosen by a runtime probe and proven by the E2E.
- **No trusting a write that landed.** Every NTFS-adjacent claim above is
  asserted by a test that fails when the claim is false — the harness's
  founding lesson (`docs/agent-lessons.md`).

## Residual risk, stated plainly

The youngest component we rely on is kernel `ntfs3` in read-write mode
for the user-data bridge (host profile folders bound into `$HOME`). A
future `ntfs3` regression could corrupt files it writes through those
binds — that is a real exposure, shared with every dual-boot setup on the
same kernel. Its bounds: the FUSE fallback exists on every image, the
bridge binds *live* data rather than migrating copies (so nothing is
deleted from the Windows side by design), the Linux OS itself is not
reachable through that driver, and every supported image's bridge is
exercised nightly by the E2E before users see it.
