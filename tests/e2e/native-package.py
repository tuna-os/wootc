#!/usr/bin/env python3
"""Assemble and check the native shell package the GUI E2E installs.

The native shell (WOOTC_E2E_GUI_FRONTEND=native) runs only from a protected
package: a directory whose native-package.json names every file by SHA-256,
with a buildId and brandId that match the ones compiled into the shell and the
engine (shell/Wootc.Shell.Native/ProtectedPackage.cs, app/native_package_windows.go).
shell/packaging/write-manifest.ps1 writes that manifest for the preview
installer; this is the same contract for the E2E, which builds the engine on
the Linux runner (it must embed the run's manifest-signing public key) beside
a shell published on Windows.

  write DIR BUILD_ID BRAND BRAND_JSON   record DIR's files in DIR/native-package.json
  check DIR                             verify DIR against its manifest; print its identity

Both refuse the screen gallery build (-p:NativeGallery=true): it replays
recorded fixtures instead of talking to an engine, so an E2E driven through it
would prove nothing about an install.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

MANIFEST = 'native-package.json'
REQUIRED = ('wootc-engine.exe', 'Wootc.Shell.exe', 'Wootc.Shell.dll', 'Wootc.Shell.pri', 'Branding/brand.json')
BRANDS = ('wootc', 'tunaos', 'aurora', 'bazzite', 'bluefin')
FILE_LIMIT = 4096
MANIFEST_LIMIT = 1024 * 1024


class PackageError(Exception):
    pass


def gallery_markers(files):
    """Paths that only the screen gallery build publishes."""
    return sorted(f for f in files if f.startswith('Fixtures/') or Path(f).name.startswith('Wootc.Shell.Gallery.'))


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def observe(root):
    if not root.is_dir() or root.is_symlink():
        raise PackageError(f'native package directory is absent: {root}')
    files = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise PackageError(f'symbolic link in native package: {path.relative_to(root)}')
        if path.is_dir():
            continue
        relative = path.relative_to(root).as_posix()
        if relative == MANIFEST:
            continue
        if ':' in relative or '\\' in relative:
            raise PackageError(f'unsafe native package path: {relative}')
        files[relative] = digest(path)
    if len(files) > FILE_LIMIT:
        raise PackageError('native package exceeds the file limit')
    return files


def require(files):
    missing = [name for name in REQUIRED if name not in files]
    if missing:
        raise PackageError('native package lacks ' + ', '.join(missing))
    gallery = gallery_markers(files)
    if gallery:
        raise PackageError('this is the screen gallery build, never an E2E shell: ' + ', '.join(gallery[:3]))


def identity(build, brand):
    if not re.fullmatch(r'[0-9a-f]{40}', build or ''):
        raise PackageError('buildId must be 40 lowercase hex digits')
    if brand not in BRANDS:
        raise PackageError(f'unknown brand: {brand!r}')


def write(root, build, brand, brand_json):
    root = Path(root)
    identity(build, brand)
    if (root / MANIFEST).exists():
        raise PackageError('refusing to overwrite an existing native manifest')
    files = observe(root)
    require(files)
    if files['Branding/brand.json'] != digest(Path(brand_json)):
        raise PackageError('package branding differs from the selected source brand')
    body = json.dumps({'schemaVersion': 1, 'protocolVersion': 1, 'buildId': build,
                       'brandId': brand, 'files': files}, separators=(',', ':'), sort_keys=True).encode()
    if len(body) > MANIFEST_LIMIT:
        raise PackageError('native manifest exceeds the size limit')
    with (root / MANIFEST).open('xb') as stream:
        stream.write(body)
    return build, brand, len(files)


def check(root):
    root = Path(root)
    path = root / MANIFEST
    if not path.is_file() or path.is_symlink():
        raise PackageError('native package has no manifest')
    if path.stat().st_size > MANIFEST_LIMIT:
        raise PackageError('native manifest exceeds the size limit')
    try:
        manifest = json.loads(path.read_bytes())
    except ValueError as error:
        raise PackageError(f'native manifest is not JSON: {error}') from None
    if not isinstance(manifest, dict) or set(manifest) != {'schemaVersion', 'protocolVersion', 'buildId', 'brandId', 'files'}:
        raise PackageError('native manifest has unexpected fields')
    if manifest['schemaVersion'] != 1 or manifest['protocolVersion'] != 1:
        raise PackageError('native manifest version is not 1')
    identity(manifest['buildId'], manifest['brandId'])
    recorded = manifest['files']
    if not isinstance(recorded, dict):
        raise PackageError('native manifest files must be an object')
    observed = observe(root)
    require(observed)
    if observed != recorded:
        changed = sorted(set(observed) ^ set(recorded) | {k for k in observed if recorded.get(k) != observed[k]})
        raise PackageError('native package differs from its manifest: ' + ', '.join(changed[:5]))
    return manifest['buildId'], manifest['brandId'], len(observed)


def main(argv):
    try:
        if len(argv) == 6 and argv[1] == 'write':
            build, brand, count = write(argv[2], argv[3], argv[4], argv[5])
        elif len(argv) == 3 and argv[1] == 'check':
            build, brand, count = check(argv[2])
        else:
            print(__doc__.strip(), file=sys.stderr)
            return 2
    except (PackageError, OSError) as error:
        print(f'native-package: {error}', file=sys.stderr)
        return 1
    print(f'buildId={build} brandId={brand} files={count}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
