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


# Unit/activation publication is one owned transaction, separate from the
# earlier module-only control. Target-native labeling runs inside this context.
from contextlib import contextmanager

UNIT_NAME = 'wootc-observer.service'
UNIT_PATH = 'etc/systemd/system/' + UNIT_NAME
ENABLE_PATH = 'etc/systemd/system/multi-user.target.wants/' + UNIT_NAME


@contextmanager
def observer_transaction(deployment, bundle, expected):
    deployment, bundle = Path(deployment), Path(bundle)
    directory(deployment)
    directory(bundle)
    names = FILES | {UNIT_NAME}
    if type(expected) is not dict or set(expected) != names:
        raise ValueError('authenticated observer/unit catalogue unavailable')
    sources = {}
    for name in sorted(names):
        value = read_owned(bundle / name)
        if type(expected[name]) is not str or hashlib.sha256(value).hexdigest() != expected[name]:
            raise ValueError('observer/unit authenticated source mismatch')
        sources[name] = value
    targets = {name: deployment / (UNIT_PATH if name == UNIT_NAME else NAMESPACE + '/' + name) for name in names}
    enabled = deployment / ENABLE_PATH
    if any(os.path.lexists(path) for path in [*targets.values(), enabled]):
        raise ValueError('observer/unit activation collision')
    made_dirs, made_files, completed = [], [], False
    def ensure(path):
        planned = []
        cursor = path
        while not os.path.lexists(cursor):
            planned.append(cursor)
            cursor = cursor.parent
        directory(cursor)
        for item in reversed(planned):
            item.mkdir(mode=0o755)
            facts = item.lstat()
            made_dirs.append((item, facts.st_dev, facts.st_ino))
            directory(item)
    def sync_dir(path):
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    def current():
        for name, path in targets.items():
            facts = path.lstat()
            recorded = next(row for row in made_files if row[0] == path)
            if (facts.st_dev, facts.st_ino) != recorded[1:3] or hashlib.sha256(read_owned(path)).hexdigest() != expected[name]:
                raise ValueError('installed observer/unit identity changed')
    def enable():
        nonlocal completed
        if completed:
            raise ValueError('observer activation must not repeat')
        current()
        ensure(enabled.parent)
        enabled.symlink_to('../' + UNIT_NAME)
        facts = enabled.lstat()
        made_files.append((enabled, facts.st_dev, facts.st_ino, 'link'))
        if not stat.S_ISLNK(facts.st_mode) or facts.st_uid != 0 or os.readlink(enabled) != '../' + UNIT_NAME:
            raise ValueError('owned observer activation link readback differs')
        sync_dir(enabled.parent)
        current()
        completed = True
    def objects():
        return [{'path': '/' + str(path.relative_to(deployment)), 'device': dev,
                 'inode': ino, 'kind': 'directory'} for path, dev, ino in made_dirs] + [
            {'path': '/' + str(path.relative_to(deployment)), 'device': dev,
             'inode': ino, 'kind': 'link' if kind == 'link' else 'file'}
            for path, dev, ino, kind in made_files]
    try:
        for name in sorted(names):
            dest = targets[name]
            ensure(dest.parent)
            fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o644)
            try:
                facts = os.fstat(fd)
                made_files.append((dest, facts.st_dev, facts.st_ino, 'file'))
                os.fchmod(fd, 0o644)
                value = memoryview(sources[name])
                while value:
                    count = os.write(fd, value)
                    if count <= 0:
                        raise OSError('observer/unit write made no progress')
                    value = value[count:]
                os.fsync(fd)
            finally:
                os.close(fd)
            if read_owned(dest) != sources[name]:
                raise ValueError('observer/unit installed bytes differ')
            sync_dir(dest.parent)
        current()
        yield {'hashes': dict(expected), 'enable': enable, 'objects': objects}
        if not completed:
            raise ValueError('observer installation lacks verified activation')
        current()
        facts = enabled.lstat()
        recorded = next(row for row in made_files if row[0] == enabled)
        if (facts.st_dev, facts.st_ino) != recorded[1:3] or not stat.S_ISLNK(facts.st_mode) or facts.st_uid != 0 or os.readlink(enabled) != '../' + UNIT_NAME:
            raise ValueError('observer activation changed before commit')
    except BaseException:
        for item, dev, ino, kind in reversed(made_files):
            if os.path.lexists(item):
                facts = item.lstat()
                right_type = stat.S_ISLNK(facts.st_mode) if kind == 'link' else stat.S_ISREG(facts.st_mode)
                if (facts.st_dev, facts.st_ino) != (dev, ino) or not right_type:
                    raise ValueError('rollback refuses foreign observer/unit inode')
                item.unlink()
                sync_dir(item.parent)
        for item, dev, ino in reversed(made_dirs):
            facts = item.lstat()
            if (facts.st_dev, facts.st_ino) != (dev, ino) or not stat.S_ISDIR(facts.st_mode):
                raise ValueError('rollback refuses changed observer/unit directory')
            item.rmdir()
        raise
