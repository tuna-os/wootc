"""Dormant owned file transaction. Caller must establish authenticated mount/policy.

This is not a builder hook or installation entrypoint. The reviewed caller must
first verify selected target/stateroot, target interpreter/stdlib, policy, and
read-only source mount. No guest request can invoke this function.
"""
import hashlib
import os
from pathlib import Path
import stat

MAX = 128 * 1024
FILES = {'boot_probe.py', 'wootc_ancestry.py'}
NAMESPACE = 'var/usrlocal/lib/wootc/observer'


def directory(path):
    for item in (path, *path.parents):
        facts = item.lstat()
        if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != 0 or facts.st_mode & 0o022:
            raise ValueError('unprotected or linked observer directory')


def regular(path):
    directory(path.parent)
    facts = path.lstat()
    if not stat.S_ISREG(facts.st_mode) or facts.st_uid != 0 or facts.st_mode & 0o022 or facts.st_nlink != 1 or facts.st_size > MAX:
        raise ValueError('observer source is not a protected bounded single-link file')
    return facts


def read_owned(path):
    before = regular(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        opened = os.fstat(fd)
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            raise ValueError('source inode changed before read')
        value = bytearray()
        while len(value) <= MAX:
            part = os.read(fd, min(4096, MAX + 1 - len(value)))
            if not part:
                break
            value.extend(part)
        after = regular(path)
        if len(value) > MAX or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError('source changed during read')
        return bytes(value)
    finally:
        os.close(fd)


def install_owned_bundle(deployment, bundle, expected):
    """Install only reviewed bytes after independent caller preflight.

    Preserve all prior files. Roll back only newly owned unchanged inodes.
    The service is not enabled here; unit/enable publication is a later boundary.
    """
    deployment, bundle = Path(deployment), Path(bundle)
    directory(deployment)
    directory(bundle)
    if type(expected) is not dict or set(expected) != FILES:
        raise ValueError('authenticated source catalogue unavailable')
    sources = {}
    for name in sorted(FILES):
        value = read_owned(bundle / name)
        digest = expected[name]
        if type(digest) is not str or len(digest) != 64 or hashlib.sha256(value).hexdigest() != digest:
            raise ValueError('authenticated source hash mismatch')
        sources[name] = value
    namespace = deployment / NAMESPACE
    planned = []
    cursor = namespace
    while not os.path.lexists(cursor):
        planned.append(cursor)
        cursor = cursor.parent
    directory(cursor)
    # Refuse existing files before any directory or file mutation.
    if any(os.path.lexists(namespace / name) for name in FILES):
        raise ValueError('observer file already exists')
    created_dirs, created_files = [], []
    try:
        for item in reversed(planned):
            item.mkdir(mode=0o755)
            facts = item.lstat()
            created_dirs.append((item, facts.st_dev, facts.st_ino))
            directory(item)
        for name, value in sources.items():
            dest = namespace / name
            directory(namespace)
            fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o644)
            try:
                facts = os.fstat(fd)
                created_files.append((dest, facts.st_dev, facts.st_ino))
                os.fchmod(fd, 0o644)
                view = memoryview(value)
                while view:
                    count = os.write(fd, view)
                    if count <= 0:
                        raise OSError('observer write made no progress')
                    view = view[count:]
                os.fsync(fd)
            finally:
                os.close(fd)
            if read_owned(dest) != value:
                raise ValueError('installed observer bytes differ')
        fd = os.open(namespace, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        return {name: hashlib.sha256(read_owned(namespace / name)).hexdigest() for name in sorted(FILES)}
    except BaseException:
        for item, dev, ino in reversed(created_files):
            if os.path.lexists(item):
                facts = item.lstat()
                if (facts.st_dev, facts.st_ino) != (dev, ino) or not stat.S_ISREG(facts.st_mode):
                    raise ValueError('rollback refuses changed observer inode')
                item.unlink()
        for item, dev, ino in reversed(created_dirs):
            facts = item.lstat()
            if (facts.st_dev, facts.st_ino) != (dev, ino) or not stat.S_ISDIR(facts.st_mode):
                raise ValueError('rollback refuses changed observer directory')
            item.rmdir()
        raise
