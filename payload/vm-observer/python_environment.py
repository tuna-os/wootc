"""Read-only interpreter/stdlib preflight for target-owned -I -S -B execution."""
import hashlib
import os
from pathlib import Path
import stat
import sys
import sysconfig


def protected_path(path, directory=False):
    path = Path(path)
    # Interpreter symlinks may be part of the authenticated OS. Every link's
    # actual ancestors must be protected; the resolved regular file is measured.
    original = path
    seen = set()
    while path.is_symlink():
        if path in seen or len(seen) >= 32:
            raise ValueError('interpreter dependency link cycle')
        seen.add(path)
        _ancestors(path.parent)
        link = path.lstat()
        if link.st_uid != 0:
            raise ValueError('unprotected dependency link')
        value = os.readlink(path)
        path = Path(value) if value.startswith('/') else path.parent / value
    resolved = path.resolve(strict=True)
    if path != resolved:
        raise ValueError('linked dependency ancestor unsupported')
    _ancestors(resolved.parent)
    facts = resolved.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(facts.st_mode) or facts.st_uid != 0 or facts.st_mode & 0o022:
        raise ValueError('interpreter dependency is unprotected')
    return original, resolved


def _ancestors(path):
    for item in (path, *path.parents):
        facts = item.lstat()
        if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != 0 or facts.st_mode & 0o022:
            raise ValueError('unprotected interpreter ancestor')


def inspect_environment():
    if not sys.flags.isolated or not sys.flags.no_site or not sys.dont_write_bytecode:
        raise ValueError('target installer requires -I -S -B')
    _, executable = protected_path(sys.executable)
    roots = set()
    for key in ('stdlib', 'platstdlib'):
        _, root = protected_path(sysconfig.get_path(key), directory=True)
        roots.add(root)
    files = {executable}
    for name, module in list(sys.modules.items()):
        spec = getattr(module, '__spec__', None)
        origin = getattr(spec, 'origin', None)
        if not origin or origin in ('built-in', 'frozen'):
            continue
        _, resolved = protected_path(origin)
        if not any(resolved.is_relative_to(root) for root in roots):
            raise ValueError('loaded dependency is outside target stdlib')
        files.add(resolved)
    if len(files) > 128:
        raise ValueError('stdlib dependency inventory exceeds bound')
    hashes, total = {}, 0
    for file in sorted(files):
        before = file.lstat()
        if before.st_size > 64 * 1024 * 1024:
            raise ValueError('interpreter dependency exceeds bound')
        digest = hashlib.sha256()
        size = 0
        with file.open('rb') as stream:
            while True:
                part = stream.read(65536)
                if not part:
                    break
                size += len(part)
                total += len(part)
                if size > 64 * 1024 * 1024 or total > 128 * 1024 * 1024:
                    raise ValueError('interpreter dependency bytes exceed bound')
                digest.update(part)
        after = file.lstat()
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError('interpreter dependency changed during measurement')
        hashes[str(file)] = digest.hexdigest()
    return {'interpreter': str(executable), 'stdlibRoots': sorted(map(str, roots)), 'loadedDependencies': hashes}
