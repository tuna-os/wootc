# ESP chain test code

This code is for a new private test disk. It does not change a saved VM.
The OS boot, Windows scripts, and firmware test have not run.
Issue #333 stays open.

Run the input check first. Each input has a path and a SHA256 hash.
The JSON file must name the Windows disk, Linux cloud disk, old and new
packages, both complete EFI sets, the Windows volume, and firmware files.
It must also name the OS, verifier files, and a free space floor of 20 GiB.
The code copies each input to a new private file before it uses the input.
A source change makes the code stop.

The Debian case needs all 24 old and 20 new package files from the signed
index plan. The code checks their hashes and package fields, then copies
them to a private folder. It checks the list of all current packages before
any install. Apt uses only local files, with no download or source list.

The old install may remove only the two packages for initramfs in that
plan. The new install must remove none. The code checks the full package
list again after the install. RPM and Ubuntu package sets still need their
own complete plan from a signed index.

The image must not use an external disk or data file.
The space check uses the real virtual size, source sizes, and a reserve.
The 20 GiB floor alone does not prove enough space.

```bash
python3 tests/e2e/esp-chain/produce-classic.py PRIVATE_PARENT CONFIG.json
# This command writes a new test disk. It needs a separate source review.
python3 tests/e2e/esp-chain/produce-classic.py PRIVATE_PARENT CONFIG.json --execute
```

The test needs a QEMU process with the new scratch UUID, disk, and private
QGA socket. The code checks all three against the real process.

The QEMU start code has not run. It keeps a fixed copy of the firmware
store and gives QEMU a separate copy to write. The first guest must match
the pinned firmware hashes before an upgrade. Do not start a VM from this
note. No test disk was made for this source check.

```bash
# After the test VM and firmware store pass review:
python3 tests/e2e/esp-chain/orchestrate.py SCRATCH SCRATCH/plan.json --bootstrap-classic
python3 -m unittest discover -s tests/unit -p 'test_wootc_*.py'
```

The QGA test uses a real local socket. Its OS and signature facts are test
inputs. It cannot prove an OS boot. Each read and wait has one end time.
The tests cover a blocked reply, slow reads, byte flow, and no progress.
A stale Windows reply must fail the new random check value.

Each capture keeps the exact bytes of the SBAT variable and their hash.
The plan keeps the exact old and new bytes and the new shim hash.
A new policy must be an exact policy in that signed source shim.
The other trust variables must stay fixed. The first boot must match the
pinned firmware files. No firmware policy change was made here.

At Windows boot, the SBAT runtime value may be unknown. The old shim can
set the expected first policy, but that plan is not a runtime fact.
The first Linux capture must read the current EFI variables and match the
old source, EFI files, root, and fresh receipt before an upgrade.

The launcher needs a JSON file with the keys below. Each of the three
files has a path and a SHA256 hash. It checks the bytes of db and dbx in
the real NV store against the guest export. This does not prove Secure
Boot. The fresh guest check must prove that state.

```json
{"qemu":{"path":"/usr/bin/qemu-system-x86_64","sha256":"REVIEWED_HASH"},
 "firmwareCode":{"path":"PINNED_CODE","sha256":"REVIEWED_HASH"},
 "firmwareStore":{"path":"PINNED_VARS","sha256":"REVIEWED_HASH"},
 "memoryMiB":8192,"cpus":4,"tpmMode":"none-unencrypted-qa"}
```

```bash
# Read only; no VM start:
python3 tests/e2e/esp-chain/launch.py SCRATCH LAUNCH.json
# Do not use --execute until the source and scratch inputs pass review.
```

Windows must have encryption off on system and host volumes.
The real Windows command must confirm that state before BCD arm and after
return. There is no TPM in this test. These Windows commands have
not run. The local process tests use a small C program. They do not start
QEMU or prove a boot.

The asset plan is in
`evidence/2026-09-27-esp-orchestrator/classic-asset-plan.json`.
It lists the missing disk, package, host, and firmware inputs.
The Windows baseline plan is in the same folder. It needs matching TPM
state. This launcher cannot make that baseline. No saved VM is a substitute.
