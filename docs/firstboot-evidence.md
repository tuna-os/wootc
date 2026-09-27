# Installed Linux boot evidence

Windows can say that Linux booted only after it checks the record of that boot.
A deployer progress word alone cannot prove it.

## Installation identity

The installer writes `install/installation.json` before it returns success.
OEM tests write the same record. It contains a fresh 128-bit ID, arm time,
selected image, staged ESP GUID and EFI loader path, full NTFS serial,
and `/wootc/disks/root.disk`. It survives removal of `armed.json` by recovery.
A new attempt resets `installed-linux-boot.complete`. It keeps the old record;
its old ID cannot prove the new attempt.

The NTFS identity uses all 64 bits of the serial returned by
[FSCTL_GET_NTFS_VOLUME_DATA](https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-ntfs_volume_data_buffer).
The 32-bit serial from `GetVolumeInformation` cannot match the UUID Linux reads.

## Linux observations

The service runs after the private host mount and profile bridge complete.
Its Python collector reads the current EFI boot number, GPT partition GUID,
loader path, Secure Boot variable, kernel, image ref and digest from bootc,
and the actual mounted NTFS UUID. It follows the installed root device to the
loop file and checks the kernel arguments against the installation identity.
It records real bind mounts, matched Windows profiles and Linux users,
BitLocker mount status, failed units, and time.

If EFI files cannot be read, `efibootmgr -v` can supply the complete boot path.
Malformed EFI data cannot trigger that fallback. Secure Boot still needs its EFI variable.
The collector refuses incomplete or mismatched facts and any failed unit.
The deployer records the actual installed image ref, which can be a local derivative;
it keeps the selected registry source separate.

The service publishes `installed-linux-boot.json` before `state.json = healthy`.
It then publishes a local summary and the completion marker.
A failure leaves the service eligible to retry on the next boot.
The NTFS writer preserves the Windows ACL on each record.

## Windows and the UI

Windows checks the fresh ID, selected source, timestamp, current host UUID,
current ESP GUID and recorded loader. A missing or invalid record cannot set
`UninstallInfo.deployed` or remove recovery controls. The CLI refuses a
healthy claim it cannot verify. A staged system can still offer its first boot.
The control panel shows the verified kernel, selected image and bridge counts.
The native-move done screen shows those facts as the verified boot before the move.
It does not treat them as proof of a later native boot.

The public Linux summary contains only kernel, selected image, image digest,
folder and user counts, and time. It does not expose the private UUIDs,
paths, or profile mappings to ordinary Linux users.

## Evidence and remaining gate

Five tests passed on Windows, with all their subcases. They cover record checks,
new IDs and the full NTFS API. [Native output](experiments/evidence/2026-09-27-firstboot-record/native-go.log)
and [source hashes](experiments/evidence/2026-09-27-firstboot-record/native-go-provenance.json) retain the result.
OEM tests also passed on Windows; a mutation that kept the stale completion marker failed.
A mutation that skipped the current ESP check failed its Go test.
Python tests cover truncated and ambiguous EFI paths, wrong volumes and images,
bridge observations, fallback rules, and summary privacy.

[Issue #332](https://github.com/tuna-os/wootc/issues/332) remains open.
A hosted full cycle must prove actual `BootCurrent`, loop-root observations,
record publication, UI summary and the Windows cross-check on the final code.
Local fixtures do not prove that cycle.
