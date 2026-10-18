# Classic ESP source control

Date: 2026-09-27. Issue: #333. Base: PR #452 at `7807416`.

The Debian source contract reads the current loop root. It checks the NTFS UUID,
root.disk path, root filesystem UUID, BootCurrent and destination ESP. It does
not create a bootc image identity for a classic OS.

The source can be a FAT partition inside root.disk or a directory on the measured
root filesystem. The destination ESP cannot also be the source. The complete
Debian trio must match the canonical files from three packages with signed payloads.
It checks the package owners, architecture, versions and status. It checks
these facts and file hashes again after the snapshot.

The stamp contains facts about the OS, kernel, filesystem and packages, with hashes of the components. The transaction checks that stamp against its frozen signed trio. It uses
the existing signature, ownership, archive and recovery controls.

The public Debian 13 GRUB update from `1+2.12+9` to `1+2.12+9+deb13u2` passed the
real signature verifier and transaction. The archive retained the whole old trio.
The verifier refused a change to GRUB without a change to the ESP trio. The
Debian 12 to 13 pair failed the mixed SBAT check; that check remains required.

Root, mount and package observations in this probe are explicit fixtures. Its EFI
trust anchors are public certificate fixtures. It does not prove a firmware boot
or an installed classic OS boot. Ubuntu, RPM and other package source contracts
remain open. The classic provisioner and real OS gate also remain open. This test did not start a VM.

Run the probe with the public asset directory and the pinned verifier closure:

```sh
python3 tests/probe-classic-esp-chain-real.py PUBLIC_ASSET_DIRECTORY VERIFIER_CLOSURE
```

The [receipt](evidence/2026-09-27-classic-esp/provenance.json) contains source and
asset hashes, public package URLs and the acceptance scope. The result files in
that directory contain the signature and publication checks.
