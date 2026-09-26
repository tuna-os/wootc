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

## Native tests

Run these commands from an elevated Windows checkout:

```powershell
cd app
go test -run '^TestState(DescriptorTrust|Tree|Drive)' -v .
cd ..
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/e2e/test-state-trust.ps1
```

Use the narrow Go selector. Other existing `TestState` tests write the Windows
path for state. Tests on Linux cannot check ACLs on Windows.

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
