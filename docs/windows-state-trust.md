# Windows installer state trust

The app checks the state of the installer before GUI or command-line startup. It checks
existing `wootc` trees on fixed drives. It checks the selected data drive again
before installation.

New state directories get a protected DACL at creation. SYSTEM and
Administrators have full control. There is no interval with inherited user
write access.

The checks apply these rules to existing files and directories:

- SYSTEM, Administrators or TrustedInstaller as owner.
- No write, delete, owner-change or ACL-change grant to other accounts.
- No unsafe grants that future children can inherit.
- No symlink, junction or other reparse point.

Users can retain read access. CREATOR OWNER can pass rights to children.
Only trusted accounts can create children. The app rejects an ACE of unknown type. A deny entry does not cancel an unsafe allow entry in this policy.

The volume root must not grant user rights to delete children or change its
ACL. The volume can give users rights to create folders. The app protects the root of
each new data volume it formats. It does not change an existing volume's ACL.

The checks follow Microsoft's [file access rules](https://learn.microsoft.com/en-us/windows/win32/fileio/file-security-and-access-rights)
and [ACE inheritance rules](https://learn.microsoft.com/en-us/windows/win32/secauthz/ace-inheritance-rules).

## Existing files and offline use

The app stops if it finds unsafe state. It does not change the contents or
permissions. An administrator must inspect it and move it aside before they
try again. An ACL reset cannot show who wrote the existing files.

Safe offline bundles remain usable. OEM and GUI scripts use
`tests/e2e/state-trust.ps1` before they copy files. An error in this step stops launch.
These local checks do not replace signed release manifests.

An empty state directory is not evidence of installation. Downloads, brand files and
the app executable are also not evidence. Discovery uses generated lifecycle,
power, root-disk, boot and recovery records. ESP files and dedicated volumes
can also show that installation began.

## Recovery and ownership authority — current-source update, 2026-11-02

Unreadable/corrupt install journals and orphaned armed/deployer markers fail
closed as **needs repair**. They are not evidence that no installation exists.

Removal keeps the Linux disk by default. Current uninstall must observe BCD
rollback before it removes recovery tasks, EFI files and installer state.
It captures errors from recursive removal; an issued command does not prove cleanup.
If secret overwrite/sync fails, uninstall refuses to unlink the unsanitized secret.
It retains a visible failure and does not claim sanitization passed.

The installer durably writes prior Fast Startup/hibernation state to the power-state
file and a registry mirror that it owns **before** it disables those settings.
Restore must observe its result and retain retry authority if it fails.
Only `WootcOwner=wootc-install-v1` establishes ownership of the Add/Remove key.
The installer refuses to change or remove an unmarked or foreign key with the same name.
There is no ownership-adoption shim.

Recovery-password preparation validates all eight groups/checksums and retains
canonical hyphens, without the secret in errors.
Linux must make the sealed file and directory durable before it destroys plaintext.
A host-only seal keeps a local key on the disk.
It therefore does **not** protect against an attacker who can read the entire unencrypted image of the disk.
On a TPM machine, the seal path refuses a default-PCR downgrade and retains root-only plaintext for retry.

Host-only fallback applies only without a usable TPM.
Default uninstall removes known installer subtrees and only empty disk/root directories.
It will preserve the unfamiliar saved data and the VM metadata, even when a known root disk is absent.
Explicit Linux-data deletion keeps its recursive product-tree scope; partition removal still needs its receipt.
These are source contracts, not newly observed BCD, firmware, sanitization or
power-restoration acceptance. The hardware/RC failure and retry matrix remains
required.

## Native tests

Run these commands from an elevated Windows checkout:

```powershell
cd app
go test -run '^TestState(DescriptorTrust|Tree|Drive)' -v .
cd ..
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/e2e/test-state-trust.ps1
```

Use the narrow Go selector. Other existing `TestState` tests write the Windows
path for state. A test on Linux cannot check the ACLs on Windows.

## Corral evidence — 2026-09-26

Native Go and PowerShell 5.1 tests passed. The tests failed when we disabled
the checks. They covered safe creation and offline copies, unsafe owners and
write grants, missing DACLs, writable precreated trees and junctions.

The production app refused a default-permission tree owned by Administrators.
Its ACL gave write rights to Authenticated Users. Fresh protected startup
and repeated `status` calls passed. The app refused a child file with user write rights. Its contents stayed
unchanged. We removed that file and startup succeeded.

We tested a new NTFS volume on a temporary virtual disk of 128 MiB. PowerShell
protected its root and created state. The app accepted that state. The test
then detached and deleted the virtual disk.

Before merge, complete deployment and Linux-to-Windows return with BitLocker
off and on. Confirm acceptance after Linux writes the lifecycle files.
