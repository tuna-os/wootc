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

```bash
python3 tests/e2e/esp-chain/produce-classic.py PRIVATE_PARENT CONFIG.json
# This command writes a new test disk. It needs a separate source review.
python3 tests/e2e/esp-chain/produce-classic.py PRIVATE_PARENT CONFIG.json --execute
```

The test needs a QEMU process with the new scratch UUID, disk, and private
QGA socket. The code checks all three against the real process.
The QEMU start code and its firmware store are still owed. Do not start a
VM from this note. No test disk was made for this source check.

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
