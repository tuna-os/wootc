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
review. The developer OEM and GUI staging paths use the same conservative
policy through `tests/e2e/state-trust.ps1`, before copying any artifacts. The
helper is delivered with both the OEM-local and SMB payloads; a failed GUI
staging gate stops the run before launch.

An empty protected state directory reserved at startup is not a partial
installation. Provisioned executables, branding and offline boot artifacts also
do not imply that Install was clicked. Discovery uses generated lifecycle,
power-restoration, root-disk, boot-configuration and recovery records; it still
recognizes boot artifacts on the ESP and dedicated data volumes.

## Windows validation

The native ACL tests require an elevated Windows process. They use temporary
folders, never the machine's actual `C:\wootc` or boot configuration:

```powershell
go test -run '^TestState(DescriptorTrust|Tree|Drive)' -v .
```

Cross-compiling the app or running its Linux tests cannot validate Windows ACL
behavior. Before merging, run the native cases and check the OEM/offline rerun
and Linux-to-Windows return on a real Windows fixture, including the BitLocker
storage-volume path. In particular, confirm the owner and DACL of lifecycle
files written from Linux.

## Verification record — 2026-09-26

On the disposable Corral/KubeVirt Windows fixture:

- Native descriptor and filesystem tests passed. An alternate binary with the
  owner, mutation-grant and reparse checks disabled failed the corresponding
  assertions, including writable manifests, writable roots and reparse points.
- The production app's `status` command refused a default `MkdirAll` state root
  before reading state. The root was owned by Administrators, but inherited
  Authenticated Users mutation rights from `C:\`.
- After moving that confirmed-empty test root aside, production `status`
  created a protected SYSTEM/Administrators-only root and returned
  `{"state":"absent"}` twice. Adding a writable child caused an exit-1 refusal;
  the planted content was unchanged. After removing that test child, `status`
  succeeded again.

The native selector above is intentionally narrow: existing lifecycle tests
also start with `TestState` and write the actual `statePath()` on Windows.
Do not broaden it on a machine with installed state.

These results prove the Windows checks and entrypoint behavior, not a complete
installation cycle. The OEM/GUI staging helper was also exercised on Windows PowerShell 5.1:
protected creation, copied offline fixtures and safe reruns succeed; unsafe
ownership, mutation grants, absent DACLs, writable precreated trees and
junctions fail for the expected reason without repairing ACLs or content.
Linux-written NTFS state and BitLocker-volume compatibility still need an
end-to-end run.

Run the native staging-helper contract test from an elevated Windows checkout:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/e2e/test-state-trust.ps1
```
