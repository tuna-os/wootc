"""Dormant authenticated bind-input guard; no mount or installer entrypoint.

The owned wrapper must first create and mount its private read-only namespace.
This guard checks the successful current mount row and each retained source
inode/hash before an installer callback can run. Device identity alone is not
source identity. No guest protocol can supply these paths or hashes.
"""
import hashlib
from pathlib import Path


def verify_bound_input(source, bound, expected, expected_mount_source,
                       expected_major, execute, findmnt, observed_mount,
                       read_owned, regular, directory):
    source, bound = Path(source), Path(bound)
    if type(expected) is not dict or not expected or len(expected) > 16:
        raise ValueError('authenticated fixed input catalogue unavailable')
    if any(type(name) is not str or '/' in name or name in {'', '.', '..'} or
           type(digest) is not str or len(digest) != 64 or
           any(c not in '0123456789abcdef' for c in digest)
           for name, digest in expected.items()):
        raise ValueError('authenticated input catalogue malformed')
    if type(expected_mount_source) is not str or not expected_mount_source:
        raise ValueError('exact bound source observation unavailable')
    directory(source)
    directory(bound)
    source_dir, bound_dir = source.lstat(), bound.lstat()
    if (source_dir.st_dev, source_dir.st_ino) != (bound_dir.st_dev, bound_dir.st_ino):
        raise ValueError('bound source directory inode differs')
    row = observed_mount(execute, findmnt, '/run/wootc-observer-input',
                         expected_major, True)
    if row['source'] != expected_mount_source:
        raise ValueError('actual bound source subtree differs')
    retained = {}
    for name, digest in sorted(expected.items()):
        original, mounted = source / name, bound / name
        before = regular(original)
        current = regular(mounted)
        identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        if identity != (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns):
            raise ValueError('bound source file inode differs')
        if hashlib.sha256(read_owned(original)).hexdigest() != digest or hashlib.sha256(read_owned(mounted)).hexdigest() != digest:
            raise ValueError('bound source hash differs')
        after = regular(original)
        final = regular(mounted)
        if identity != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) or identity != (final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns):
            raise ValueError('bound source changed during readback')
        retained[name] = {'device': before.st_dev, 'inode': before.st_ino,
                          'sha256': digest}
    directory(source)
    directory(bound)
    if (source.lstat().st_dev, source.lstat().st_ino) != (source_dir.st_dev, source_dir.st_ino) or (bound.lstat().st_dev, bound.lstat().st_ino) != (bound_dir.st_dev, bound_dir.st_ino):
        raise ValueError('bound directory changed during validation')
    return retained


def invoke_verified_input(install, **observations):
    """No invocation until the complete current closure verifies successfully."""
    retained = verify_bound_input(**observations)
    return install(retained)
