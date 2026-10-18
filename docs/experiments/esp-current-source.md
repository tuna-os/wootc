# Current source candidate for ESP refresh

Date: 2026-09-27. Issue: #333. Main base: `323b7ba`.

The candidate combines the reviewed transaction and classic source checkpoints.
It keeps the original receipts as records of their original source commits.
The new receipt pins the combined source and the harness checks.

Providers implemented: bootupd, Debian, Ubuntu, classic RPM and copies of versioned RPM payloads. Versioned RPM support covers the paths with the installed EVR for
shim-x64 and grub2-efi-x64. It checks canonical ownership and file hashes before it accepts FAT copies. The probe uses public Bluefin/Fedora data. It proves facts about packages and their signatures. It does not prove a Fedora upgrade or classic OS boot.

## Harness commands

The helpers under `tests/e2e/esp-chain` do not launch a VM or publish images.
`scratch.py` creates a private overlay of an immutable QA baseline with an installed OS. The caller must supply its SHA256. Each overlay gets a new scratch ID
and VM UUID. Pass that UUID to QEMU with `-uuid`.

Never reuse a live VM, its TPM
state or its writable firmware variables. The runner must create private copies
of those files for this scratch identity.

```sh
python3 tests/e2e/esp-chain/scratch.py PRIVATE_PARENT BASELINE.qcow2 SHA256
```

The baseline must already contain Windows and Linux in an installed loop root with
the old signed trio. The classic baseline must have a real distro installation,
its package database, an NTFS loop attach that works, QGA and the production ESP helper.
A package fixture is not that baseline. The producer must create this baseline and prove that it boots; this overlay helper does not replace an OS installer.

Run `capture.py` in each installed Linux boot. It uses the production observer,
source collector, signature verifier and ownership checks. It reads actual EFI
variables and compares their hashes before and after capture. The new-generation
captures also verify the old archive against the new source and actual firmware
policy. Pass the JSON with hashes of the old trio with `--old-hashes` for those captures.

```sh
python3 capture.py --esp MOUNT --uuid FAT_UUID > old.json
python3 capture.py --esp MOUNT --uuid FAT_UUID --old-hashes old-hashes.json > new.json
```

The runner must use the real package upgrade or `bootc upgrade`, then capture the
new deployment and a later boot through its refreshed chain. It must not edit
/usr, create a fake package database or forge a bootupd stamp to supply a source.
For bootc, pin both OCI digests and use a QA reference for this run only. For classic,
pin the published package bundles and record the measured source facts.

Stage the Windows helper with CRLF and its UTF-8 BOM before execution. The checked-in source uses LF.

After the later Linux boot, run `capture-windows.ps1` through the real QGA transport for Windows. It checks Windows_NT, reads the VM UUID and queries the actual
NTFS serial with FSCTL_GET_NTFS_VOLUME_DATA. Pass the scratch ID, the last observed Linux boot ID and the actual root.disk volume. The volume argument is mandatory. The helper checks that root.disk exists there before it queries the NTFS serial. The transport must execute this after the return to Windows; a record from an earlier Windows boot cannot satisfy this gate.

The scratch ID and prior Linux boot ID are caller inputs. Their echo does not prove execution order. The helper compares facts from each capture. It returns observationsMatch, with chronologyVerified and firmwareAcceptance false.
The orchestrator must record the execution order of actual QGA calls and reject a cached Windows response. That code remains open.

```sh
python3 tests/e2e/esp-chain/accept.py plan.json old.json new.json reboot.json windows.json
```

The plan includes schemaVersion, scratchId, vmUuid, oldHashes, newHashes and
identity. Identity contains hostUuid, hostEspUuid, rootDiskPath, loaderVendor,
deploymentKind and bootCurrent. Classic also needs rootFsUuid. Bootc also needs
imageRef, oldImageDigest and newImageDigest in the plan.

The assertion needs distinct boot IDs for each Linux boot. The EFI entry and NTFS root must stay the same. Source and ESP hashes must match the pinned bundles.

It checks the complete old archive, ownership and foreign ESP files. It verifies signatures across both generations. It checks units and the later Windows return on the same VM and NTFS volume.
Tests use mutations to check these refusals. They use explicit fixtures and
are not firmware evidence.

The orchestrator and producer of a real classic baseline remain open. Execution of the Windows helper and the hosted firmware run also remain open. Process-cut and hardware power-cut cases remain
separate gates. We did not dispatch a VM for this candidate. Firmware and classic
OS acceptance are false. Initial cross-vendor publication, a new ESP identity for a native root
and kernel/initramfs pair atomicity remain separate #286/#234 work.
