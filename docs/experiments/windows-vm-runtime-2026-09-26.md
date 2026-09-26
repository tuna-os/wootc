# Windows VM runtime experiment, 2026-09-26

The VM-first path needs a runtime that the installer can verify and fetch.
A user should not need to find and install QEMU by hand.
This experiment tests a smaller x86 bundle. It does not enable a new release asset.

## Build

`packaging/build-vm-runtime.py` checks the pinned installer SHA-512 before extraction.
It does not run the upstream installer. It retains the x86 emulator, all root DLLs,
x86 firmware, display data, documentation and license files.
It adds the helper kernel, initramfs and protocol file from a local build.

Each file enters `SHA256SUMS`. The build signs that manifest with the release seed.
The seed stays outside the bundle. The app must embed the matching public key.
The outer release manifest must also cover the ZIP before the app extracts it.
See [artifact authentication](../artifact-authentication.md) for the trust model.

```bash
python3 packaging/build-vm-runtime.py \
  --helper-dir /path/to/helper-artifacts \
  --signing-seed /private/build/seed \
  --output /path/to/wootc-vm-runtime.zip
```

Go, Python 3.11 or later, and 7-Zip must be available.
Use `--installer` for a cached input. The same hash check still applies.
Use `--seven-zip` when the extraction tool is outside PATH.

## Measured results

| Artifact | Bytes |
|---|---:|
| Upstream installer | 206,615,928 |
| Full upstream installation, all architectures | 1,255,998,954 |
| Selected runtime, with helper, unpacked | 321,059,722 |
| Selected runtime ZIP, with helper | 183,295,958 |

The signed manifest covers 3,282 files. The checks passed for the signature and each file hash
after ZIP creation. The [bundle record](evidence/2026-09-26-vm-runtime/bundle.json)
pins the ZIP and public key. The helper came from commit `4f9985d`.
It predates account setup; a release must use the final contract for the helper.

The probe copied the ZIP to a temporary directory on the Corral Windows 11 fixture.
It checked SHA-256 before extraction. PATH excluded the installed QEMU copy.
The probe used private temporary and home directories and cleared display overrides.

- Headless TCG executed the boot-sector marker in 0.545 seconds.
- GTK in Windows session 1 executed the same marker in 2.540 seconds.
- Loaded modules came from the bundle or Windows system directories.
- GTK accepted `window-close=off,show-menubar=off`.

The [headless log](evidence/2026-09-26-vm-runtime/windows-tcg.log) and
[interactive log](evidence/2026-09-26-vm-runtime/windows-gtk-interactive.log)
record those checks. The scripts in the same directory show their scope.
These short TCG probes do not measure a Linux desktop or its performance.

An earlier GTK test in session 0 failed to execute the marker in 30 seconds.
GDK reported that no monitor existed. Its
[failure log](evidence/2026-09-26-vm-runtime/windows-gtk-session0.log) remains in the record.
The repeat used a task with an interactive principal and no time trigger.
It did not change the runtime files or display flags.
Do not launch the desktop from a service session.

## Remaining release gates

Prove helper preparation and a usable Linux desktop with this exact bundle.
Test restart, persisted work, shutdown, keyboard input and missing dependencies.
The app must offer a clear shutdown control when the QEMU close button is disabled.

Complete verified download, bounded extraction and atomic runtime publication in the app.
Do not expose a partial runtime or trust an unsigned local manifest.

Record the exact corresponding source and build inputs for QEMU and its DLLs
before distribution. The upstream binary reports commit `e470268ff4`;
this experiment did not resolve the source commit or full dependency record.
The license files do not complete that provenance work.
No release workflow publishes this experimental ZIP.
