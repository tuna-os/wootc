# Boot artifact checks — 2026-09-27

Seven tests passed on Windows from main `ac211264f38d91047c2e15ac65ff3ba6578bbca2`.
The test binary SHA-256 is
`5d325b98cef3a0a33f79c351904730100eddd76e370680c8891733c7b4336592`.
The [log](evidence/2026-09-27-artifact-auth/native-windows.log),
[script](evidence/2026-09-27-artifact-auth/native-windows.ps1), and
[build record](evidence/2026-09-27-artifact-auth/provenance.json) retain the result.

## Method

Built the Windows Go test binary from the source above. Ran it through QGA
on `winbase-399`, after PowerShell reported `Windows_NT`.
The script created a new private temporary directory, restricted its ACL to
SYSTEM and Administrators, and checked the binary hash before execution.
It removed that directory when the tests exited. Tests used temporary files
and local TLS servers. They did not write to the Windows installation or boot chain.

The first invocation failed before tests ran: PowerShell parsed the unquoted
Go flags as `-test`. Quoted flags passed on the next invocation. The saved
script uses those quoted flags. No failed invocation counts as a test pass.

## Result

- A staged manifest needs the embedded key and a valid signature.
- Downloads of boot files must use HTTPS. They do not use proxy settings from the environment.
- A downloaded manifest needs a valid signature.
- An invalid manifest in the staging directory stops the install without a download.
- Manifest and signature reads have size limits.
- The environment cannot change the source of boot files.
- The downloader on Windows checks signatures and hashes of cached files.
  It removes optional files without a signed hash and repairs a corrupt cache.
  It rejects corrupt downloads and forged manifests.

These tests support the fix for [#371](https://github.com/tuna-os/wootc/issues/371)
in [#416](https://github.com/tuna-os/wootc/pull/416). The
[authentication contract](../artifact-authentication.md) describes the key and release process.
This run does not prove a full installation, GUI use, or trust in the installer itself.
Authenticode, release freshness, and full boot identity have separate open gates.
