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


def mapped_files():
    with Path('/proc/self/maps').open('rb') as stream:
        raw = stream.read(128 * 1024 + 1)
    if len(raw) > 128 * 1024:
        raise ValueError('mapped dependency inventory exceeds bound')
    result = {}
    for line in raw.decode('ascii').splitlines():
        fields = line.split(maxsplit=5)
        if len(fields) < 5:
            raise ValueError('malformed mapped dependency')
        if len(fields) == 5:
            if 'x' in fields[1]:
                raise ValueError('unidentified executable mapping')
            continue
        name = fields[5]
        if name.startswith('['):
            if 'x' in fields[1] and name not in ('[vdso]', '[vsyscall]'):
                raise ValueError('unknown executable kernel mapping')
            continue
        if not name.startswith('/usr/') or name.endswith(' (deleted)'):
            raise ValueError('mapped dependency outside protected target usr')
        _, file = protected_path(name)
        facts = file.lstat()
        dev = fields[3].split(':')
        if len(dev) != 2 or (os.major(facts.st_dev), os.minor(facts.st_dev), facts.st_ino) != (int(dev[0],16), int(dev[1],16), int(fields[4])):
            raise ValueError('mapped dependency inode identity mismatch')
        identity = (facts.st_dev, facts.st_ino)
        if file in result and result[file] != identity:
            raise ValueError('mapped dependency identity changed')
        result[file] = identity
    if len(result) > 128:
        raise ValueError('mapped dependency count exceeds bound')
    return result


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
    mappings = mapped_files()
    files.update(mappings)
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
    if mappings != mapped_files():
        raise ValueError('mapped dependencies changed during measurement')
    return {'interpreter': str(executable), 'stdlibRoots': sorted(map(str, roots)), 'loadedDependencies': hashes,
            'mappedDependencies': sorted(map(str, mappings))}
