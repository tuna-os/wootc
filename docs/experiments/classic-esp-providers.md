# Classic source providers

Date: 2026-09-27. Issue: #333. Base checkpoint: `9c4bdb6`.

The source contract now covers Debian, Ubuntu and classic RPM layouts. All use
the same checks for the current loop root, private NTFS host and BootCurrent.
The source must stay inside root.disk and cannot alias the destination ESP.

Ubuntu uses the selected shim alternative. The target of that link must belong
to shim-signed and stay on the measured root filesystem. MokManager also belongs
to shim-signed. GRUB belongs to grub-efi-amd64-signed. A change to the selected
alternative during the snapshot stops publication.

The contract for RPM needs shim-x64 and grub2-efi-x64. It reads their installed
versions, architecture and SHA256 file digests. Each source file must have a
normal installed state and a regular file type. The digest must match the source
bytes. The OS identifies the vendor directory. These contracts apply to the classic layouts of Fedora, AlmaLinux, Rocky, CentOS and RHEL.

The collector reads every package query again after the snapshot. This includes
package names, owners, versions, architecture, status and file metadata. Tests
change owners and package names during the snapshot and check for refusal.

The public Ubuntu 24.04 GRUB update passed the real signature verifier, archive
and transaction. The RPM test installed the public Alma packages into a private
root with scripts and triggers disabled. It used the real RPM database and query
binary to bind the source bytes. Its GRUB update passed the same controls.
The verifier refused changes to GRUB and left the ESP trio intact.

Root, mount and OS observations remain explicit fixtures. The Ubuntu package
observations use fixture data from the public control headers. The RPM database
contains records of installed packages. The EFI variables contain public test
anchors.

These tests do not prove an installed classic OS boot or a firmware boot.
The classic provisioner and real OS gate remain open. Other package layouts need
source contracts and tests. Issue #333 remains open.

```sh
python3 tests/probe-classic-providers-real.py PUBLIC_ASSETS VERIFIER_CLOSURE
```

The [receipt](evidence/2026-09-27-classic-providers/provenance.json) contains hashes
of the source and assets, with package URLs and the acceptance scope. It also identifies the query binary.
