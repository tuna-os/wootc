# Installed Linux boot evidence

Windows can say that Linux booted only after it checks the record of that boot.
The deployer status alone does not prove a Linux boot.

## Installation identity

The installer writes `install/installation.json` before it returns success.
OEM tests write the same record. It contains a fresh 128-bit ID, arm time,
selected image, staged ESP GUID and EFI loader path, full NTFS serial,
and `/wootc/disks/root.disk`. It survives removal of `armed.json` by recovery.

A new installation resets `installed-linux-boot.complete`. It keeps the old record.
That ID does not match the new installation.

The NTFS identity uses all 64 bits of the serial returned by
[FSCTL_GET_NTFS_VOLUME_DATA](https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-ntfs_volume_data_buffer).
The 32-bit serial from `GetVolumeInformation` cannot match the UUID Linux reads.

## Linux observations

One collector writes the record: `payload/migration/lib/wootc_firstboot_evidence.py`.
The record is the schema-1 record of `wootc status` (#332).
The service runs after the private host mount and profile bridge complete.

The collector reads the kernel, the boot ID and the Secure Boot variable.
It reads the image ref and digest from bootc, after the sysroot lock.
It decodes the current EFI boot entry, or it uses `efibootmgr -v`.
It follows `/sysroot` to the loop device of `root.disk`, by the rule of the ESP controller.
It reads the UUID of the mounted NTFS volume.

The collector then compares the boot with `install/installation.json`.
The boot must start after the arm time.
The kernel arguments must name the root disk and host UUID of the identity.
The recorded source image must be the selected image.
The booted image must be the image that the deployer installed, which can be a local derivative.

A decoded boot entry must be the staged ESP and loader.
When the firmware does not let Linux decode the entry, the collector writes `unavailable`.

The record lists each folder bind with its source, target and Linux user.
A bind of the whole Windows volume or of the `wootc` records stops the check.
The collector sets `bitlockerUnlocked` only for the bridge mapping of an actual BITLK volume.
Both bridge units must complete.
The record also lists the units that failed. Linux does not refuse the boot for them.

The service publishes `installed-linux-boot.json` before `state.json = healthy`.
It then publishes a local summary and the completion marker.
A failure leaves the service eligible to retry on the next boot.
When the record of this installation exists without the marker, the service does not measure again: it completes the publication.
The service measures again over the record of another installation.
The NTFS writer preserves the Windows ACL on each record.

## Windows and the UI

Windows reads the record as untrusted strict JSON.
Windows checks the installation ID, the arm time, the selected source,
the host volume, the root disk and a decoded ESP GUID and loader.
A failed `wootc-` unit makes the boot unhealthy.

`UninstallInfo.deployed` also needs the current ESP GUID and the current host UUID.
A missing or invalid record cannot set `deployed` or remove recovery controls.
The CLI refuses a healthy claim that it cannot verify. A staged system can still offer its first boot.

The control panel shows the verified kernel, selected image and bridge counts.
The native-move done screen shows those facts as the verified boot before the move.
It does not treat them as proof of a later native boot.

The public Linux summary contains only kernel, selected image, image digest,
folder and user counts, and time. It does not expose the private UUIDs,
paths, or profile mappings to ordinary Linux users.

## Evidence and remaining gate

Eleven tests passed on Windows, with all their subcases. They cover record checks,
new IDs, the full NTFS API and the status audit. [Native output](experiments/evidence/2026-09-27-firstboot-record/native-go.log)
and [source hashes](experiments/evidence/2026-09-27-firstboot-record/native-go-provenance.json) retain the result.
OEM tests also passed on Windows. A mutation that kept the stale marker for completion failed.
A mutation that skipped the check of the current ESP failed its Go test.

Tests in Python check truncated and ambiguous EFI paths, wrong installations, volumes and images,
bridge observations, fallback rules, and summary privacy.

[Issue #332](https://github.com/tuna-os/wootc/issues/332) remains open.
A hosted full cycle must prove actual `BootCurrent`, loop-root observations,
record publication, UI summary and the Windows cross-check on the final code.
Local fixtures do not prove that cycle.
