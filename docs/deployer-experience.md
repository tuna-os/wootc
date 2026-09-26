# Deployer experience

The text display shows the current stage and elapsed time. Its animation is
not a measure of work done. A stage can take a long time with no new message.
The display does not infer success from time, disk use, or a live process.

The display keeps the text console path for older PCs. Diagnostics stay in the serial output and in files on disk. Debug mode still shows the raw console.
The display says that Linux will start only after the existing boot checks pass.

## Baseline

| Evidence | Observation |
|---|---|
| [Hosted GUI run 33402962420](https://github.com/tuna-os/wootc/actions/runs/33402962420), 2026-08-31, commit `37152bc22fc2332a10d048b84761c2cc81a519b9` | Reboot directive at 14:52:45 UTC; deploy verification observed at 15:05:52 UTC: about 13 minutes 7 seconds |
| Scope | One hosted VM run. The interval includes boot and host polling. It is not a benchmark for an older PC. The retained job log does not give a complete split by stage. |
| Display change | Removes a registry query with a 60-second timeout that ran only to estimate display progress. No measured speed gain is claimed. |

## Next steps

| Priority | Work | Evidence required |
|---|---|---|
| First | Record time for image import, install, initramfs build, and disk flush | Monotonic stage events plus observed completion or failure |
| Next | Use structured fisherman events for more detail | Missing, delayed, and failed events must never imply success |
| Next | Add optional distro art and colors | Text fallback, bounded text, no terminal control codes from metadata, and a real old-GPU check |
| Later | Reduce duplicate image import and export | Compare the same image and hardware; retain digest checks and crash recovery |
| Required first experience | Prepare and run Linux in a VM while Windows stays open | A complete VM boot, resource limits, and clear hardware checks |

Phase 1 must run Linux in a VM inside Windows first, as specified in
[ADR 0001](adr/0001-phase1-first-architecture.md). The display work here applies
to the later native transition and the existing recovery path.

A helper VM can reuse the provisioner to prepare `root.disk`. It must not mount
the host NTFS filesystem while Windows has it mounted. Windows must hand off
exclusive access to the disk file, and the helper must receive only that file
and staged inputs. A later native boot must use the same `root.disk` without a
second install. This needs a separate proof of the VM path; a good splash
is not that proof.
