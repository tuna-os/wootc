# BitLocker fixture and status repair — 2026-09-27

[Run 36295716220](https://github.com/tuna-os/wootc/actions/runs/36295716220)
failed on `ec1cfd549ecb26c39c5448b73a5093016785bc65`.
It booted installed Linux and returned to Windows. It did not prove the copy of Documents.

## Observed defects

The real CLI reported `absent` while its state file existed on the trusted F: volume.
The status command did not find the volume used for the installation.
The CLI now finds a unique trusted installation across fixed drives.
It refuses unsafe, malformed, or ambiguous records without repair of their permissions.
A payload directory on C: does not select the installation.

The encrypted C: fixture had no recovery password protector.
OEM capture warned and continued without a key. Linux could not unlock C: and made no copies.
The fixture now creates a missing protector before capture and checks the private key file.
A failure stops setup before boot configuration changes. Refresh uses the existing protector.

This is test fixture preparation; it does not change the product's BitLocker support gate.

## Local checks

Six tests of status passed on Windows from `eaf2cd26af65345af4e643546ea08394b7c445b8`.
They used private files in temporary directories with unsafe ACLs and a reparse point.
The [log](evidence/2026-09-27-bitlocker-fixture/native-status.log) and
[build record](evidence/2026-09-27-bitlocker-fixture/native-status-provenance.json) retain the result.
A [mutation](evidence/2026-09-27-bitlocker-fixture/status-ambiguity-negative.log)
that removed the ambiguity check failed its test.

Seven [tests of the key file](evidence/2026-09-27-bitlocker-fixture/native-recovery-key.log)
passed on Windows with mock BitLocker commands.
The tests used actual file permissions.
They did not change the fixture's encryption state.
A [mutation](evidence/2026-09-27-bitlocker-fixture/recovery-key-negative.log)
that removed the failure throw failed its test.
All 616 Bats tests passed. Go tests, Windows compilation, PowerShell syntax checks,
Bash syntax, ShellCheck, and diff checks passed.

A fresh hosted BitLocker run is still needed. GUI edit, save, close, reopen,
and restart proof remains needed for #427 and #431. These local checks do not prove it.
