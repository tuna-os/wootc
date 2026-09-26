# Smaller VM capacity trial

Status: proposed experiment. No production default changes.

The current host profile creates two sparse 40 GiB files and needs 88 GiB
free on the Windows volume. This sum includes an 8 GiB Windows reserve.
The helper at `0cb8776` rejects either disk below 32 GiB. The signed account
bundle remains unchanged. A 32 GiB target plus 16 GiB scratch is not valid
under that helper contract.

## Proposed contract

The helper owner must approve the field names and version before the host
uses them. Use separate `minimumTargetDiskBytes` and
`minimumScratchDiskBytes` in the signed `builder-protocol.json`. The values
are lower bounds for the helper, not proof that every image fits.

Keep the current 32 GiB bound for each disk in the first contract change.
A later experimental profile can reduce the scratch bound to 16 GiB after
its tests pass. A legacy contract with `minimumDiskBytes` keeps that value
for both disks. Do not interpret a missing field as zero.

The host must verify the signed runtime before it reads this contract.
It must reject unknown versions, invalid bounds, zero or negative values,
numeric overflow, and unsupported disk sizes. Both separate fields must
exist together. If the legacy field also exists, it must be at least as
large as each separate bound. Thus legacy 32 with separate 32/16 is valid.

A profile must bind its image digest and helper version to the evidence.
Do not apply a smaller image's capacity result to any other OCI reference.

## Experiment order

1. Wait for the active desktop test and Windows writer to finish.
2. Validate the new helper contract with separate bounds at 32/32 GiB.
3. Use new, dedicated 32/16 GiB disks for a named experimental profile.
   Keep both serial checks, blank-disk checks and mount checks. Validate
   both disks before the first format operation.
4. Pin the repaired image digest. Use account creation through the private
   input channel. Retain the complete receipt and helper process exit.
5. Boot the same target with its persistent firmware variables. Sign in,
   create a document, shut down cleanly, restart and read the document.
6. Repeat with the app on Windows. Do not infer Windows behavior or speed
   from the KVM helper trial.

Use a fixture with enough physical storage for the chosen upper bound.
A larger thin volume does not create physical capacity. The current Windows
clone has an 80 GiB logical volume and cannot pass the 88 GiB profile.
Its shared storage's reported 35 GiB free does not prove safe expansion.

## Measurements

Record a sample with its timestamp each second through the full trial:

| Layer | Observable |
|---|---|
| Windows | Volume free bytes; allocated bytes of each sparse file; QEMU memory |
| Helper | Target and scratch capacity, used bytes and free bytes |
| Hypervisor | Actual allocated bytes and backing-volume free bytes |
| Desktop | Free bytes after login, document creation and clean restart |

Record peak use and the final sizes of the files. Keep the same image digest,
helper hash, QEMU version, RAM, CPU settings and sample interval with the
results. A missing sample period is a limit on the result.

The candidate admission bound is 32 + 16 + 8 = 56 GiB, after runtime setup.
This is an experimental bound, not a proven product minimum. Account for
host logs and temporary files as well. Measure physical use before any
future policy relies on sparse allocation instead of full virtual capacity.

## Host changes after approval

`app/vm_image_windows.go` needs separate target and scratch capacities.
Its free-space check must use checked addition of both capacities and the
Windows reserve. Its file creation must retain exclusive creation, sparse
file setup, exact logical lengths, sync, and close checks.

`app/vm_windows.go` must select the verified image profile before it creates
files. Store the chosen profile and capacities with the installation record.
A restart must preserve the existing disk size and GPT identity. It must
never resize an existing disk to match a new default.

`app/vm_space.go` samples the free space in Windows during preparation. Keep its
cancellation cause and wait for the helper process to exit before the host releases the writer
lock. A sample every second cannot promise that another
Windows app never consumes the reserve between samples.

The host retains scratch after success. Reclaim it only after the helper
has exited, its job has closed, and the verified receipt is durable. Delete
only the known scratch path under the protected tree and image lock. Never
delete the target or firmware variables. Preserve failed-run scratch until
a policy for recovery exists.

## Targeted acceptance tests

| Case | Required observable |
|---|---|
| Legacy 32 GiB metadata | Both minimums remain 32 GiB; 16 GiB scratch rejected |
| Separate 32/32 GiB metadata | Same admission and disk behavior as legacy |
| Missing or invalid bounds | Rejection before any disk write |
| Candidate 32/16 profile | Accepted only for the measured immutable image |
| Exact admission boundary | 56 GiB accepted; one byte less rejected |
| Sum overflow | Rejection before file creation |
| Wrong scratch serial or existing signature | No format operation on either disk |
| Scratch one byte below its minimum | No format operation on either disk |
| Existing target | Contents and length unchanged after refusal |
| Real low-space transition during helper writes | Child exits; lock retained until reaped; no success receipt accepted |
| Clean helper completion | Durable target identity precedes scratch removal |
| Failed helper or malformed receipt | Target preserved; no ready or desktop-ready status |
| Restart after a new default | Same target, firmware, account and saved document |

Mutation checks must remove a bounds check, swap the two bounds, release the
lock early, or accept a success marker without its receipt. Each mutation
must fail its corresponding test. Filesystem creation alone is not evidence
of a completed install or a usable desktop.

## Read-only fixture inventory

The Windows inventory found no active QEMU process. It measured
53,979,086,848 bytes free (50.272 GiB). The files from our experiments
consume 4,576,790,880 bytes (4.262 GiB). Even removal of all these files
would leave a 1,573,664,416-byte shortfall below 56 GiB.

| Artifact | Allocated bytes | Disposition |
|---|---:|---|
| Partial helper target | 2,717,515,776 | Preserve; no completed helper receipt |
| Installed QEMU | 1,255,998,954 | Keep until a replacement runtime is validated |
| Old probe directory | 267,311,706 | Archive and check test ownership before any removal |
| Cached QEMU installer | 206,615,928 | Host copy exists; removal alone cannot resolve the shortfall |

The inventory did not delete files. Logs are already archived by the runner.
The raw [inventory](evidence/2026-09-26-managed-vm/fixture-space-inventory.json)
and [disk geometry](evidence/2026-09-26-managed-vm/fixture-disk-geometry.json)
record the measurements. There is no duplicate runtime ZIP in this clone.

The virtual disk is 95,156,174,848 bytes. The C: partition ends before an
822,083,584-byte recovery partition. Windows reports the current C: size
as its maximum supported size. Windows cannot use the space after recovery to extend C: directly. This agrees with the [Windows extension rules](https://learn.microsoft.com/en-us/windows-server/storage/disk-management/extend-a-basic-volume).

The shared filesystem sample had 37,363,535,872 bytes free (34.8 GiB).
After the cluster's 26 GiB guard, only 8.8 GiB remained for new writes.
This cannot cover the candidate's 48 GiB of virtual target and scratch.
The `local-path` StorageClass does not enable volume expansion. A change
to its PVC size would not prove more physical capacity. See the
[KubeVirt storage requirements](https://kubevirt.io/user-guide/storage/disks_and_volumes/).

A concrete alternative is a fresh Windows fixture with at least a 128 GiB
virtual disk. Keep the old fixture and its evidence. First add at least
100 GiB of physical filesystem capacity on the storage node. At the measured
free space, that would give about 134.8 GiB before new writes.

Budget 32 GiB for Windows and 48 GiB for target and scratch.
Add 8 GiB for the Windows reserve and 8 GiB for fixture assets and logs.
Keep 26 GiB for the cluster guard. This totals 122 GiB, with about 12.8 GiB
margin in that sample. Recheck the free space after the tests for capacity finish.
This calculation is a plan, not a reservation.

Use a new volume large enough to expose the full virtual disk. Confirm
its size in Windows after creation. Measure C: free bytes before admission.
Do not alter the old recovery partition to get test space. A sparse file does not satisfy the physical budget.
Neither does a larger size in the PVC request.
