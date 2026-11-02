# Managed Windows VM lifecycle

The VM uses one Linux system in `<drive>:\wootc\disks\root.disk`.
A restart reuses that image and `vm\firmware-vars.fd`.
It does not redeploy Linux. Native promotion needs more proof (ADR 0004).

The [2026-10-30 decision on #596](https://github.com/tuna-os/wootc/issues/596#issuecomment-6514382140)
chose **Option A: VM-first remains required for RC**. A closed VM
issue does not prove the desktop or same-image native-promotion gate.
The source contracts below do not claim that the latest published tag
contains a complete, usable product with a VM-first workflow.

Standard releases still need to publish the signed runtime package.
The GUI offers explicit setup through `InstallVMRuntime`.
An executable alone is insufficient. The engine checks the complete runtime
against a signature before execution. An absent bundle makes the capability
unavailable. It does not cause a silent fallback to native install.

Setup fetches the signed release manifest before it downloads
`wootc-vm-runtime.zip`. An absent entry gives a clear unavailable error.
The download has a 256 MiB limit. Extraction verifies the archive hash and
each signed file, then publishes the complete directory in one rename.

Setup owns the image lock. It needs a protected parent and 2 GiB free.
Cancellation removes temporary files. A retry removes only reserved temporary
paths; it preserves an existing runtime and every Linux disk.

## Runtime contract

Stage QEMU for Windows 11.1.0 under `wootc\qemu`.
The tested installer supplies these files:

| Path | Purpose |
|---|---|
| `qemu-system-x86_64.exe` | VM process, with all its DLLs and support files |
| `share/edk2-x86_64-code.fd` | Firmware code; 3,653,632 bytes |
| `share/edk2-i386-vars.fd` | Firmware template; 540,672 bytes; copy once per installation |
| `builder-vmlinuz`, `builder-initramfs.img` | Initial preparation helper |
| `SHA256SUMS`, `SHA256SUMS.sig` | Domain-bound manifest, signed by the key embedded in this installer |

The manifest uses canonical relative paths, with no ambiguity about case.
Every runtime file must match the manifest. It rejects a DLL absent from the list. It also rejects links and changed files. Logs and writable firmware data stay outside this tree.
The installer checks permissions and reparse points before it loads the runtime.

QEMU uses an absolute path and a protected directory.
Its environment has an explicit allowlist. It does not inherit user PATH,
GTK/GIO/QEMU module paths, or user configuration locations.

WHPX must be enabled. The launcher selects `-cpu max`.
Before it enables preparation, the engine boots a small probe with WHPX.
The probe must emit a marker from actual guest code through a fresh serial file.
It uses a read-only disk with no operating system or user files.

The check has a 30-second deadline. A timeout is inconclusive on a slow or busy PC;
it does not prove incompatibility.
The cache expires after one minute and keys on the signed manifest.
The measured mode is `whpx,kernel-irqchip=off`; there is no TCG fallback.

Each image still needs proof of CPU compatibility, especially with x86-64-v3.
A process does not prove acceleration, guest boot, or a usable desktop.

## Preparation and ownership

| Boundary | Required evidence or behavior |
|---|---|
| Target and scratch | Separate 40 GiB raw files; serials `wootc-root` and `wootc-scratch` |
| Helper memory | 3 GiB guest allocation; at least 6 GiB host RAM; lower-memory profiles need separate proof |
| Host capacity | At least 88 GiB free before file creation: target, scratch, and 8 GiB for Windows |
| Image | Immutable OCI digest; fresh installation and run IDs |
| Existing file | Never truncate or replace; preserve failed preparation for diagnosis |
| Helper completion | Exit zero, one structured receipt, then `STATUS=SUCCESS` |
| Receipt identity | Exact image/run/install IDs and the GPT GUID read from the target |
| Receipt validation | `filesystemVerified=true`, `efiVerified=true`, `accountOutcome=created` and exact username |
| Result transport | Private file-backed virtio channel owned by this QEMU launch; no public socket |

The 88 GiB gate is a conservative trial limit, not a measured physical minimum.
The files are sparse. The helper stops if free space falls below the Windows reserve.
Product defaults still need a measurement of peak physical space on Windows.
A lighter image with a 2 GiB helper also needs proof for older PCs.
These are P0 requirements for the consumer path.

The host sends account input through private `fw_cfg` data.
The file contains a password hash, never a plaintext password.
It stays under the protected VM directory, outside logs and durable state.
The host removes it after the helper exits. After a crash, cleanup first takes
the image lock. It removes only account input, not the Linux disk.

The GUI reuses the Linux username and password fields. It derives the username
from Windows when possible. `PrepareVM` accepts these choices. Without an account,
`TryInVMFresh` refuses preparation.

Both host and helper accept the same account syntax: 1–32 characters,
`[a-z_][a-z0-9_-]{0,31}`. Host and helper reserve the names `root`, `nobody`, `daemon`, `bin` and `sys`.
They refuse these names before disk preparation. Passwords must be nonempty,
at most 1024 bytes, without NUL or line breaks. These choices create the Linux
account; they do not migrate Windows authentication.

This evidence proves the installed disk and the helper's account result.
A usable login and desktop still need independent guest evidence.

A mutex in Windows protects the image across engine processes.
An exclusive file handle also detects an unmanaged process that still has the
image open. Install, native boot, and uninstall use the same lock.
Native redeployment refuses a managed image until promotion can preserve it.
Uninstall locks each drive that it will clean. It keeps the disk and VM record
unless the user chooses to delete them.

## Stop, restart and recovery

The viewer disables an abrupt quit through GTK.
Use the visible **Shut down Linux** control in the main app, or shut down inside Linux.
The main app can also close itself: it first requests a guest shutdown.
These controls prevent a silent power cut when a user closes the window.

QMP uses private inherited pipes. A job object in Windows owns the QEMU process.
The host creates QEMU suspended, assigns the job, then resumes it.
A crash before assignment can leave an inert process, but no unowned writer.

If the engine exits, Windows stops that process. The engine writes state before
launch. An interruption leaves a record that needs recovery.
It never trusts a reused process ID.

| Action or state | Contract |
|---|---|
| `StopVM` | Request ACPI shutdown; wait up to 90 seconds |
| Clean stop | Actual process exit and QMP `SHUTDOWN`, with `guest=true` and `reason=guest-shutdown` |
| Shutdown timeout | Guest keeps its writer lock; no clean-stop claim |
| `ForceStopVM` | Explicit force; mark the image as `needs_recovery` |
| Engine close | Request shutdown; force after the deadline; record recovery if unclean |
| Restart | Only from `ready` or `stopped`, with the same GPT identity |
| Stale active state | Recovery required; no automatic restart |
| `desktopReady` | Always false until independent guest evidence exists |
| Launch refused before a VM process can run | Preserve the prior verified `ready`/`stopped` phase and disk; record the error so a corrected retry remains possible |
| Failure after a writer could start | Do not infer a clean stop; require observed shutdown or mark recovery |

The bounded wait allows the engine to exit. A forced stop never becomes a
clean stop. Follow-up work includes filesystem recovery, account/login proof,
a desktop probe, and promotion of the same system to native boot.

The shutdown evidence follows the [QEMU QMP reference](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html#event-SHUTDOWN).
A guest request to power off does not prove that each application saved its documents.

### Same-image native boot-input export is not promotion

Current source can try an export that does not arm boot from a VM with verified stopped state.
It uses the signed builder's advertised `export-boot` operation.
This needs a matching helper/runtime, rebuilt and re-signed; an older runtime without that operation
refuses. It attaches the existing target read-only, with no scratch disk,
network or account credentials.

The installed kernel must match its module tree and BLS entry.
A tmpfs overlay provides workspace for the installed `dracut`.
It creates a separate native initramfs with the required attach/storage closure.
It does not borrow a different kernel ABI as a fallback.

The bounded export contains fixed boot files and validated digests, bound to
the current run, installation and GPT disk identity. Artifacts stay under
`vm/native-boot-<run>`; `vm/promotion.json` records `exporting`,
`export-failed` or `boot-inputs-verified`, while VM state remains stopped.
The separate entry for native boot preserves the installed root/ostree options. A successful
export still returns **not armed**: it does not write the ESP/BCD, prove Secure
Boot/hardware readiness, or establish a native login. VM execution, filesystem
immutability and same-image native boot still need real runtime acceptance.

## Required runtime acceptance (not supplied by the helper receipt)

Use an isolated Windows 11/WHPX fixture with at least 8 GiB of host RAM.
Keep 88 GiB free on the target volume.
Use a matching signed runtime and a pinned supported image.
Keep the account and disk disposable, not a user's live PC.

1. Record Windows `LastBootUpTime`, `bcdedit /enum all`, BitLocker and Fast
   Startup before preparation. Use the actual app account/`PrepareVM` route.
2. Retain the helper receipt and matching installation/GPT disk identity.
   Log in to the real graphical desktop using the chosen account; capture it.
   In a graphical editor, save a random nonce to
   `~/Documents/wootc-vm-first.txt`, change an application preference, and reopen
   both in the guest. A shell command or receipt is not graphical-login proof.
3. Request `StopVM`. Check for guest QMP `SHUTDOWN` evidence **and** actual
   process exit before you accept `stopped` with no writer.
4. `BootInVM` must reuse the same disk path/GPT identity and firmware variables.
   Reopen the nonce/preference graphically. Confirm Windows boot identity and
   boot configuration did not change: this must not need a host native reboot.
5. Current native promotion may export boot inputs, but must report **not armed**.
   It must leave BCD/ESP and bytes on the target disk unchanged.
   A future positive gate for promotion needs native login into the **same installed system**.
   Read the VM nonce/preference, then create a second native nonce.
   Return cleanly to Windows, launch the VM again, and read both markers.
   Do not mark that gate passed from export or a redeployed image.

`desktopReady` deliberately remains false; the draft guest observer is not a
substitute for a desktop observer that independent checks verify, with installation and connections complete.
Keep receipts, guest screenshots, process/shutdown evidence, host boot
observations and exact build/image/runtime identities together.

## Probe source

The embedded boot sector is 512 bytes. Its source is in
`app/vmprobe/serial-boot.S`. Reproduce it with GNU binutils:

```sh
as --32 app/vmprobe/serial-boot.S -o /tmp/probe.o
ld -m elf_i386 -Ttext 0x7c00 --oformat binary -e _start /tmp/probe.o -o /tmp/probe.img
sha256sum /tmp/probe.img app/vmprobe/serial-boot.img
```

Both hashes must be
`f591bb62b9fce510dc7a4a096940ffbfc596d925739416559017cfb2a92e7195`.
This probe proves execution of guest instructions, not Linux or desktop compatibility.
