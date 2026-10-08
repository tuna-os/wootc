# dakota "Phase-2 hang": root cause (#218, defect #209)

Source: run [32556250889](https://github.com/tuna-os/wootc/actions/runs/32556250889),
cell `bluefin-dakota-win11pro`, job log. The evidence artifact
`e2e-bluefin-dakota-win11pro-32556250889` had a 14-day retention. It was gone
before this analysis started, so this record uses the job log only.
For a comparison, it uses the green dakota cell of run
[31085047559](https://github.com/tuna-os/wootc/actions/runs/31085047559).

## Summary

Phase 2 did not hang. Phase 2 did not start.
The deploy passed verification and rebooted.
The next boot went to Windows, and Windows did not come back.
The harness waited for Windows QGA until the 90-minute budget stopped it.
Then it reported "Deployment did not complete", which was not true.

## The three questions in the issue

1. **Did the verification stage complete before the reboot?** Yes.
   The serial shows the success path of `deploy.sh`.
   It shows the `/mnt/ntfs still busy ... lazy-detaching` warning.
   It also shows `Rebooting.`, and the harness logged `deployer requested reboot`.
   That code runs only after `DEPLOY_OK=1`.
   The serial has no `ABORT:` line and no "deployer log, last 60 lines" dump.
   The failure path writes both.
2. **Did the firmware boot the BLS entry?** No. After the reboot, the serial shows
   `BdsDxe: starting Boot0003 "Windows Boot Manager"`.
   Observed runs do not arm Phase 2 from the deployer.
   The harness arms it from Windows after the deploy, and Windows did not come back.
   In the green run, the harness read the persistent log from Windows.
   Then it armed the one-shot, and Phase 2 booted.
3. **Was `wootc-attach.service` in the Phase-2 initramfs?** We cannot know
   from the evidence that is left. This question is not on the failure path,
   because the firmware did not boot that initramfs.
   The "GUARD VERDICT" and "VERIFY STAGE MARKER" steps printed nothing in the
   green run also. Thus an empty result there is not evidence.

## First broken link

The deployer gives the Windows volume back mounted and dirty.

The final teardown in `payload/deployer/deploy.sh` runs `losetup -d` on each
loop that a file on `/mnt/ntfs` backs.
If a mount still uses that loop, `losetup -d` only sets autoclear.
The loop stays, and `root.disk` stays open on the NTFS volume.

Then `umount /mnt/ntfs` fails five times because the volume is busy.
After that, the script does a lazy detach.
A lazy detach does not close an ntfs3 superblock.
Thus `reboot -ff` resets a volume that ntfs3 still has read-write, with its dirty flag set.

In the failed run, fisherman left its target tree mounted:

```
warning: unmounting /mnt/fisherman-target/.fisherman-scratch: umount -Rl /mnt/fisherman-target/.fisherman-scratch: exit status 1
```

`/mnt/fisherman-target` is not below `/mnt/ntfs`.
Thus no step of the teardown unmounted it.

The green run also did a lazy detach, and its Windows came back.
Thus the dirty volume does not always stop Windows.
But it is the first step that is wrong, and Windows has stopped on it before.
Refer to `tests/unit/phase2-clean-ntfs-umount.bats`,
where Phase 2 left the same volume mounted and Windows went into Startup Repair.

## Changes

- `deploy.sh`: the teardown first unmounts each mount on an NTFS-backed loop.
  This includes mounts on a partition of the loop, and the mounts below them.
  Then it detaches the loop.
  If the volume is still busy, the deployer writes each holder to the serial.
  The job log keeps the serial for 90 days. GitHub deletes the artifact after 14 days.
- `run-e2e.sh`: if the deployer requested its reboot and Windows did not come
  back, the harness says so.
  It also says that the harness did not schedule Phase 2.
- `tests/unit/deployer-ntfs-teardown.bats` runs the teardown block against a
  fake `/proc/mounts`. It goes red on the old code.

## Still open

- The cell must pass two times in sequence (the "done when" of #218).
  No sweep since run 32556250889 included dakota.
- [#522](https://github.com/tuna-os/wootc/pull/522) changes dakota to the `:stable` tag, as the maintainer requested in #209.
- The catalog status of dakota is still `green`.
  The issue says to demote it if a second sweep shows the same failure.
  No sweep has shown it again.
