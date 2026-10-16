# BitLocker recovery password format — 2026-09-27

The bridge did not keep the seven hyphens in the recovery password
before it called `cryptsetup bitlkOpen`. Cryptsetup needs 55 characters:
eight groups of six digits, separated by hyphens. It rejects the 48 digits as a recovery password. Each numeric group must be divisible by
11 and fit a 16-bit value after division.

This is a verified code defect. Hosted run
[36298918499](https://github.com/tuna-os/wootc/actions/runs/36298918499)
booted Linux and returned to Windows, but the profile bridge failed to unlock
`/dev/sda3`, reported zero copies, and failed the Documents edit checks.
The run discarded cryptsetup's stderr. The password format might not explain
the whole failure. Windows also reported encryption in progress.

The fix preserves separators and accepts a single ASCII line with an optional
CRLF terminator. It rejects missing separators, BOMs, extra lines, bad group
checksums, and values outside the recovery-password range before it calls
cryptsetup. Unlock failures report the exit status and validated format;
they do not label the password stale or print it.

## Measured discriminator

Cryptsetup 2.7.0 accepted the public fixture `bitlk-aes-xts-128.img`
with its recovery password of 55 characters. The command
`bitlkOpen -r --test-passphrase --key-file=-` returned exit 0.
The same command failed after we removed only the seven separators
(exit 2, `No key available with this passphrase.`).
The test did not create a mapping or mount a volume.
It did not use or retain a password from the Windows machine.

The [result](evidence/2026-09-27-bitlocker-password-format/result.json),
[provenance](evidence/2026-09-27-bitlocker-password-format/provenance.json), and
[reproduction script](evidence/2026-09-27-bitlocker-password-format/reproduce.py)
retain the tool version, fixture hashes and outcomes. The archive and sparse
image remain local under `/tmp/wootc-bitlk-format-probe`; this commit does not include them.

To reproduce, download the pinned archive URL in provenance, check its SHA256,
and extract only `bitlk-images/images.conf` and
`bitlk-images/bitlk-aes-xts-128.img` with GNU tar's sparse support. Run:

```sh
python3 docs/experiments/evidence/2026-09-27-bitlocker-password-format/reproduce.py /path/to/bitlk-images
```

The script reads the password from the public fixture and passes it through
stdin. Its output contains lengths, exit statuses and sanitized stderr only.
The fixture has a logical size of 100 MiB; sparse extraction needs much less
physical space.

## Verification still required

The local test proves cryptsetup's format distinction. It does not prove that Windows has encrypted the whole volume.
It does not prove that the exported protector matches the selected volume.
It does not prove that Documents reaches an editable copy in Linux. The
hosted encrypted-source edit/reopen/restart and Windows-return checks remain
the gate for that claim.

Primary source:
[cryptsetup recovery-password parser](https://github.com/mbroz/cryptsetup/blob/4030da727e8323297b4ed1172138494d4926f905/lib/bitlk/bitlk.c).
