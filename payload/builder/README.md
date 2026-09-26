# VM helper contract

This helper prepares a new Linux disk inside a VM. The host must attach only files made for this VM. A host disk or partition is not an input. It does not change the host
ESP, boot menu, Fast Startup, or BitLocker state.

The current verifier supports an ostree deployment with a fallback EFI loader.
Other layouts fail closed. A success result means the disk passed these checks.
It does not prove a ready desktop or native boot.
The selected image retains its own account and first-boot policy.

| Input | Contract |
|---|---|
| `/dev/vda` | Blank target, VirtIO block serial `wootc-root`, at least 32 GiB |
| `/dev/vdb` | Blank scratch, VirtIO block serial `wootc-scratch`, at least 32 GiB |
| Capacity | These are minimums. The host must budget space for the selected image on both volumes. Large images can need more. |
| `wootc.image` | Registry reference with immutable `@sha256:` digest |
| `wootc.run_id`, `wootc.install_id` | 8–64 letters, numbers, underscores, or hyphens; first character is a letter or number |
| `wootc.ipc` | Private VirtIO serial port created by the host for this run |
| Network | VirtIO network device with DHCP; image pull needs registry access |

The helper checks both disk identities and signatures before it formats scratch.
The helper refuses a disk with partitions, a known signature, or an active mount.
The absence of a signature does not prove ownership. The host must create
and exclusively hold the image files. It must not attach other disks.

The helper uses ext4 scratch for both the container store and temporary files.
Temporary files inside the bootc container use the same disk-backed store.
It passes the target as a guest block device, without `--via-loopback`.

## Results and ownership

The host must capture serial output in a protected file unique to this run.
Both serial and IPC carry the same result JSON, followed by `STATUS=SUCCESS`.
The helper emits success only after the disk checks, sync, and scratch unmount.
The host must match the run, install, image, and disk identities. It must also
observe helper exit and release of all image handles before it starts the guest.
A process exit, a large file, or a stage message is not a success result.

```json
{
  "type": "result",
  "schemaVersion": 1,
  "status": "success",
  "runId": "run_123456",
  "installId": "install_123456",
  "image": "ghcr.io/example/os@sha256:...",
  "diskId": "GPT partition-table UUID",
  "filesystemVerified": true,
  "efiVerified": true,
  "accountOutcome": "image-default"
}
```

Errors carry `step: "error"`, a reason, and the current stage. An unexpected
command failure takes the same error path. The host must also fail if it loses
the channel, reaches its deadline, or finds no terminal result.
Keep partial target images for diagnosis. Do not erase an existing installed
disk to retry. Scratch disposal is a host action after it confirms VM exit.

## Build

```sh
bash payload/builder/build-builder.sh /path/to/output
```

The build uses a unique container and temporary directory. Its cleanup touches
only those resources. It includes VirtIO and filesystem modules from Alpine,
plus the tools used by the helper. Runtime boot tests must still prove that the
modules, network, container runtime, and selected image work together.
