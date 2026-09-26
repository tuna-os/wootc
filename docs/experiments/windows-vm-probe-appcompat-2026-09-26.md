# Windows VM capability probe mutates the signed runtime — 2026-09-26

The Corral WHPX app trial showed the VM-first action missing even though the
QEMU runtime archive had been authenticated. The exact capability response was:

```json
{
  "available": false,
  "reason": "runtime file is not signed: %SystemDrive%/ProgramData/Microsoft/Windows/Caches/cversions.2.db"
}
```

The first probe launched QEMU with its current directory set to
`C:\wootc\qemu`. Windows created `cversions.2.db` and two companion
compatibility-cache files in a literal `%SystemDrive%\ProgramData` path under
that directory. Those files were absent from the signed runtime manifest. On a
subsequent app start, the installer-state trust scan also rejected the
user-writable cache file. The manifest and trust checks behaved correctly; the
probe polluted the immutable runtime.

The probe now runs from its private `.probe-*` workspace under the disposable
preview directory. QEMU and its DLLs remain in the authenticated `qemu`
bundle, and the workspace is removed when the probe exits. A regression test
asserts that the command working directory is outside the runtime directory.

This fixes the specific runtime mutation found in the trial. Rebuild the
Windows app and repeat the visible first-launch test before treating the
VM-first capability gate as proven on Windows.
