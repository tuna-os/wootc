# Windows VM capability probe mutates the signed runtime — 2026-09-26

The Corral test on Windows showed no VM-first action, though QEMU's runtime
archive passed its check. The capability response was:

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

The probe now runs from its private `.probe-*` folder under the disposable
preview directory. QEMU and its DLLs stay in the signed `qemu` bundle. The
probe removes the folder when it exits. A regression test asserts that QEMU
starts outside the runtime folder.

The test found one way to change the signed runtime. Rebuild the Windows app
and repeat the visible first-launch test before you call VM-first ready on
Windows.
