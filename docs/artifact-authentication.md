# Boot-artifact authentication

The installer verifies `SHA256SUMS.sig` with the public key embedded in the executable.
It accepts only a manifest with a valid signature. It verifies the signature before it reads the checksums.
The same rule applies to downloads and files staged in `install/`.
A missing signature, wrong key, changed manifest, or duplicate name stops the install.

The release job creates an Ed25519 key pair before it builds the installers.
All brands from that job embed the public half. The job signs the final manifest,
verifies it, then deletes the private seed. The private seed never enters a release asset.
`artifact-public-key.hex` records the public key for audit; the installer does not trust
that downloaded file as a replacement for its embedded key.

This binds the artifacts to the installer build. It does not authenticate the installer
itself: Authenticode and trusted distribution remain separate release gates.
A compromise of the build job can still change both the installer and its artifacts.
Old unsigned releases do not gain protection from this change.

## Rotation and custody

Each release job uses a new key. There is no long-lived secret to copy
into a distro fork or developer environment. An existing installer keeps its key and
pinned release tag. Do not replace a published manifest with one signed by a new key.
Publish a new installer and tag together when a release needs a correction.
The job cannot re-sign a release after it deletes the private seed.

The signature is 64 raw bytes over the UTF-8 domain string
`wootc boot-artifact manifest v1`, one NUL byte, then the exact manifest bytes.
The verifier uses Go's standard Ed25519 implementation. It rejects manifests larger
than 1 MiB, invalid SHA-256 values, duplicate names, and paths that are not canonical relative paths.
Paths use forward slashes. The parser rejects absolute paths, parent traversal, and Windows drive syntax.
Line-ending changes invalidate the signature.

## Development and offline use

Build-time `--manifest-public-key` selects a file with a 32-byte public key in hex.
An executable built without a key can show the UI, but cannot install boot artifacts.
There is no runtime key override. The installer ignores `WOOTC_DEPLOYER_MIRROR`.
Boot downloads use HTTPS, reject a downgrade, and do not inherit proxy settings.
An offline bundle needs the manifest, its signature, and the matching installer.

`just build-wootc-exe` creates a local fixture key outside the checkout and guest share.
Both `just vm-wootc-fresh` and GUI E2E sign the staged artifacts with that same key.
Set `WOOTC_E2E_MANIFEST_KEY` on the build host to use a specific fixture seed.
Its public file is `<seed>.pub` for the local recipes.
Hosted E2E uses a fresh key in the runner's private temporary directory.
This variable is a build/harness input; it cannot change the installer's embedded key.

For a custom build, create and sign with the checked-in tool:

```bash
# Run from app/. Keep this directory outside all published or guest-shared paths.
key_dir=$(mktemp -d)
go run ./tools/signmanifest generate "$key_dir/seed" "$key_dir/public.hex"
# Build the installer with --manifest-public-key "$key_dir/public.hex".
go run ./tools/signmanifest sign "$key_dir/seed" /path/to/SHA256SUMS /path/to/SHA256SUMS.sig
go run ./tools/signmanifest verify "$key_dir/public.hex" /path/to/SHA256SUMS /path/to/SHA256SUMS.sig
rm -f "$key_dir/seed"
```
