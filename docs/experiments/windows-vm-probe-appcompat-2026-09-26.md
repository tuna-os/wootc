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
`C:\wootc\qemu`. Windows created `cversions.2.db` and two other app cache files
under a folder named `%SystemDrive%\ProgramData`. Those files were absent from the signed runtime manifest. On a
subsequent app start, the installer-state trust scan also rejected the
user-writable cache file. The manifest and trust checks worked; the probe
changed the signed runtime.

The probe now runs from its private `.probe-*` folder under the disposable
preview directory. QEMU and its DLLs stay in the signed `qemu` bundle. The
probe removes the folder when it exits. A regression test asserts that QEMU
starts outside the runtime folder.

This trial shows that the probe can change the signed runtime. Rebuild the
Windows app and repeat the visible first-launch test before you call VM-first
ready on Windows.

## Retest outcome

The first rebuilt app lacked the public key that signed the test runtime. It
refused the runtime before the probe. I recovered the old app's public key and
checked the runtime signature on the build host.

The KubeVirt log then reported a guest-agent shutdown event. Its VMI stayed
ready, but Windows did not reconnect QGA after a restart. I stopped the VMI
after 20 minutes and kept its PVC. This run did not confirm the probe fix on
Windows.
