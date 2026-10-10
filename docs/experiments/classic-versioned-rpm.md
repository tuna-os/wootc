# Versioned RPM payloads for classic sources

Date: 2026-09-27. Issue: #333. Base checkpoint: `6cc52bb`.

A classic FAT source can contain copies that the RPM database does not own.
The collector now binds these copies to the installed package payloads under
/usr/lib/efi. The path must contain the exact installed EVR, with the vendor and
component name. It checks the canonical file owner, normal installed state,
regular file type and SHA256 digest. The canonical file must stay on the measured
root filesystem. The FAT copy must match its bytes.

The public Fedora payload has shim-x64 at `0:16.1-5` and grub2-efi-x64 at
`1:2.12-64.fc44`. The native probe made 16 fresh RPM queries against the cached
immutable artifact. It verified the complete trio with the real signature
verifier. Its source facts contain OS and package data, with no bootc image fields.
The legacy Ubuntu and Alma source, archive, transaction and tamper tests also
passed after the change.

Tests refuse a foreign canonical owner, a different EVR and a canonical file on
another filesystem. Package owners and metadata undergo the same readback checks
as the previous checkpoint.

The source artifact is a Bluefin image with Fedora packages. It supplies public
payloads and installed RPM records for this test. The classic OS, root and mount
observations are explicit fixtures. Its EFI anchors are public test certificates.
The probe does not claim a classic OS boot, a firmware boot or a real upgrade
through this trio. Those acceptance gates remain open under #333.

```sh
python3 tests/probe-classic-versioned-rpm-real.py PUBLIC_ASSETS VERIFIER_CLOSURE
```

To audit the checkpoint without full result output:

```sh
python3 tests/audit-classic-chain-provenance.py WORKTREE \
  --assets PUBLIC_ASSETS --closure VERIFIER_CLOSURE \
  --evidence 2026-09-27-classic-versioned-rpm
```

The [receipt](evidence/2026-09-27-classic-versioned-rpm/provenance.json) contains
hashes of the exact source, payloads and results, with the artifact digest.
