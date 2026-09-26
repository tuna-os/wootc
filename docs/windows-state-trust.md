# Windows installer state trust

The elevated app reserves `C:\wootc` with an explicit protected DACL at
creation: SYSTEM and Administrators have inherited full control. Before reading
branding, checksums, recovery records or install state, it audits existing
`wootc` trees on fixed drives. The selected storage drive is checked again
before installation changes Windows.

An existing directory is **not** made trustworthy by resetting its permissions.
The app first checks every existing file and directory for:

- An owner of SYSTEM, Administrators or TrustedInstaller.
- No mutation grant to any other SID, including grants inherited by future
  children. Read-only access is permitted; CREATOR OWNER inheritance is allowed
  because only trusted principals may create children.
- No symlink, junction or other reparse point.

Unknown ACE types are refused. A deny ACE does not cancel an unsafe allow in
this conservative policy. An administrator-managed offline bundle with trusted
ownership and read-only access for ordinary users remains usable. An unsafe
pre-staged manifest is refused without replacing its contents or repairing its
ACL. This establishes local filesystem trust; it does not establish the
publisher authenticity of a release or replace signed manifests.

The volume root is checked as well: an ordinary user's `DELETE_CHILD` right on
the parent could bypass the protected child's delete permissions. Ordinary
create-folder rights on a volume root are allowed. The app sets a protected
SYSTEM/Administrators ACL on the root of a **new dedicated data volume** it
formats. It does not rewrite ACLs on an existing volume.

These checks follow Microsoft's [file security and access rights](https://learn.microsoft.com/en-us/windows/win32/fileio/file-security-and-access-rights)
and [ACE inheritance rules](https://learn.microsoft.com/en-us/windows/win32/secauthz/ace-inheritance-rules).

## Refusal and compatibility

A refusal names the unsafe path and reason. An administrator must inspect and
move aside untrusted state before retrying; the app does not delete it or bless
its contents. Existing permissive data-volume roots also require administrator
review. The developer OEM PowerShell harness has a separate staging path;
these app checks do not retrofit its standalone execution.

An empty protected state directory reserved at startup is not a partial
installation. Discovery still recognizes directories with actual content,
root disks, boot artifacts and dedicated data volumes.

## Windows validation

The native ACL tests require an elevated Windows process. They use temporary
folders, never the machine's actual `C:\wootc` or boot configuration:

```powershell
go test -run '^TestState' -v .
```

Cross-compiling the app or running its Linux tests cannot validate Windows ACL
behavior. Before merging, run the native cases and check the OEM/offline rerun
and Linux-to-Windows return on a real Windows fixture, including the BitLocker
storage-volume path. In particular, confirm the owner and DACL of lifecycle
files written from Linux.
