# VM trial capacity recovery — 2026-09-27

The shared node had 35,118,919,680 bytes free before this work.
The 32/8 helper trial needs room for its measured peak plus the 26 GiB node reserve.
Its earlier peak was 11,478,540,288 allocated bytes.
The reserve protects this rig; it is not a requirement for a consumer PC.

The `helper-proof` pod had no QEMU process.
Its scratch disks were already absent.
Two files remained: `root.disk` and `yellowfin-neutral.disk`.
We kept each file as a zstd archive.

For each archive, we compared the SHA-256 digest of the full raw file with the full decompressed stream.
Both streams had exactly 42,949,672,960 bytes, and both digests matched.
Only then did we remove the raw copies.
The Windows VM disks and their snapshot did not change.

| File | Raw allocated bytes | Archive bytes | Evidence |
|---|---:|---:|---|
| `root.disk` | 7,806,664,704 | 3,215,193,941 | [Round-trip record](evidence/2026-09-27-capacity-recovery/root-archive.json) |
| `yellowfin-neutral.disk` | 4,362,088,448 | 1,939,724,807 | [Round-trip record](evidence/2026-09-27-capacity-recovery/neutral-archive.json) |

The [final node sample](evidence/2026-09-27-capacity-recovery/node-after-both-archives.json)
shows 44,071,211,008 bytes free at 05:13:37 UTC.
The [file inventory](evidence/2026-09-27-capacity-recovery/retained-archives.txt)
confirms that both archives remain on the `helper-proof-data` PVC.
This capacity can change. Recheck it before and during a new trial.

Stop all writers and recheck capacity before you restore either file.
Use `zstd -d --sparse` to restore the chosen archive to a new file.
Compare its length and full SHA-256 digest with the record before use.
Keep the archive until that check passes.
These files keep the state from earlier experiments.
Neither replaces a fresh install test inside Windows.

The Windows fixture has a separate boot problem.
Its VMI had status `Running`, but QGA reported that the guest agent was not connected.
The [console capture](evidence/2026-09-27-capacity-recovery/windows-boot-screen.png)
shows the Windows boot-manager text and TianoCore logo.
The console alone does not identify the failed step.
There is no proof of a usable Windows session.
No VM reset, disk restore, or new helper trial followed from that observation.

The Windows-hosted Linux desktop, restart persistence, and native promotion gates remain open.
