"""Dormant target-owned SELinux labeling boundary; no guest command API."""
import os
from pathlib import Path
import re

NAMESPACE = Path('/var/usrlocal/lib/wootc/observer')
UNIT = Path('/etc/systemd/system/wootc-observer.service')
FILES = (NAMESPACE / 'boot_probe.py', NAMESPACE / 'wootc_ancestry.py', UNIT)
CONTEXT = re.compile(r'[A-Za-z0-9_]+:[A-Za-z0-9_]+:[A-Za-z0-9_]+:s[0-9]+(?:[-:,cs0-9]+)?')


def label_installed_files(read_protected, protected_tool, execute):
    """All callbacks are fixed installer dependencies, never wire fields.

    execute must require successful status and incremental output/deadline bounds
    before returning text. Caller owns rollback; no unit enable occurs here.
    """
    config = read_protected(Path('/etc/selinux/config')).decode('ascii')
    entries = {}
    for line in config.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        if key not in ('SELINUX', 'SELINUXTYPE'):
            continue
        if not sep or key in entries:
            raise ValueError('ambiguous target SELinux configuration')
        entries[key] = value
    mode = entries.get('SELINUX')
    if mode not in ('disabled', 'permissive', 'enforcing'):
        raise ValueError('target SELinux policy not observed')
    if mode == 'disabled':
        return {'configuredMode': mode, 'labelsRequired': False, 'serviceEnabled': False}
    name = entries.get('SELINUXTYPE', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', name):
        raise ValueError('target SELinux policy name unavailable')
    policy = Path('/etc/selinux') / name / 'contexts/files/file_contexts'
    read_protected(policy)
    setfiles = protected_tool('/usr/sbin/setfiles')
    matchpath = protected_tool('/usr/sbin/matchpathcon')
    expected = {}
    for file in FILES:
        read_protected(file)
        context = execute([str(matchpath), '-n', str(file)])
        if type(context) is not str:
            raise ValueError('target label command observation unavailable')
        context = context.strip('\r\n')
        if not CONTEXT.fullmatch(context):
            raise ValueError('target label lookup is not canonical')
        expected[file] = context
    execute([str(setfiles), '-F', str(policy), *map(str, FILES)])
    observed = {}
    for file, context in expected.items():
        value = os.getxattr(file, 'security.selinux')
        if len(value) > 4096 or value.rstrip(b'\x00').decode('ascii') != context:
            raise ValueError('installed target label differs from policy')
        observed[str(file)] = context
    return {'configuredMode': mode, 'labelsRequired': True, 'labels': observed, 'serviceEnabled': False}


# These exact paths cover only the transaction's module/unit/activation namespace.
# Directory writes below never recurse or touch existing shared parent objects.
TRANSACTION_DIRS = {
    '/var', '/var/usrlocal', '/var/usrlocal/lib', '/var/usrlocal/lib/wootc',
    '/var/usrlocal/lib/wootc/observer', '/etc', '/etc/systemd',
    '/etc/systemd/system', '/etc/systemd/system/multi-user.target.wants',
}
ACTIVATION = '/etc/systemd/system/multi-user.target.wants/wootc-observer.service'


def label_transaction_objects(objects, read_protected, protected_tool, execute):
    """Exact nonrecursive native xattrs for retained newly owned objects.

    Target policy lookup must succeed. Files, new directories and the newly
    created activation link all receive current readbacks before final commit.
    The surrounding owned installer deadline bounds the native syscall stage.
    """
    import stat
    if type(objects) is not list or not objects or len(objects) > 16:
        raise ValueError('owned label object inventory unavailable')
    config = read_protected(Path('/etc/selinux/config')).decode('ascii')
    entries = {}
    for line in config.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        if key in {'SELINUX', 'SELINUXTYPE'}:
            if not sep or key in entries:
                raise ValueError('ambiguous target SELinux configuration')
            entries[key] = value
    mode = entries.get('SELINUX')
    if mode not in {'disabled', 'permissive', 'enforcing'}:
        raise ValueError('target SELinux policy not observed')
    if mode == 'disabled':
        return {'configuredMode': mode, 'labelsRequired': False, 'labels': {}}
    name = entries.get('SELINUXTYPE', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', name):
        raise ValueError('target SELinux policy name unavailable')
    read_protected(Path('/etc/selinux') / name / 'contexts/files/file_contexts')
    matchpath = protected_tool('/usr/sbin/matchpathcon')
    seen, observed = set(), {}
    for record in objects:
        if type(record) is not dict or set(record) != {'path', 'device', 'inode', 'kind'} or record['kind'] not in {'file', 'directory', 'link'} or type(record['path']) is not str or type(record['device']) is not int or type(record['inode']) is not int:
            raise ValueError('owned label object record malformed')
        path = Path(record['path'])
        allowed = (str(path) in TRANSACTION_DIRS if record['kind'] == 'directory'
                   else str(path) == ACTIVATION if record['kind'] == 'link'
                   else path in FILES)
        if not allowed or path in seen:
            raise ValueError('label path outside owned transaction')
        seen.add(path)
        before = path.lstat()
        shape = {'file': stat.S_ISREG, 'directory': stat.S_ISDIR, 'link': stat.S_ISLNK}[record['kind']]
        if not shape(before.st_mode) or before.st_uid != 0 or (before.st_dev, before.st_ino) != (record['device'], record['inode']) or (record['kind'] != 'link' and before.st_mode & 0o022):
            raise ValueError('owned label object identity changed')
        if record['kind'] == 'link' and os.readlink(path) != '../wootc-observer.service':
            raise ValueError('owned activation link target changed')
        context = execute([str(matchpath), '-n', str(path)])
        if type(context) is not str or not CONTEXT.fullmatch(context.strip('\r\n')):
            raise ValueError('target label lookup is not canonical')
        context = context.strip('\r\n')
        if record['kind'] == 'link':
            # fsetxattr cannot operate on O_PATH symlink descriptors. Retain its
            # protected parent instead; only the sole owned installer may alter
            # names here. Check the current link after policy lookup and again
            # after native labeling. This does not claim symlink fd pinning.
            for parent in (path.parent, *path.parent.parents):
                facts = parent.lstat()
                if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != 0 or facts.st_mode & 0o022:
                    raise ValueError('activation label parent is unprotected')
            fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            try:
                parent = os.fstat(fd)
                current_parent = path.parent.lstat()
                current = path.lstat()
                if (parent.st_dev, parent.st_ino) != (current_parent.st_dev, current_parent.st_ino) or not stat.S_ISDIR(parent.st_mode) or parent.st_uid != 0 or parent.st_mode & 0o022 or not stat.S_ISLNK(current.st_mode) or current.st_uid != 0 or (current.st_dev, current.st_ino) != (record['device'], record['inode']) or os.readlink(path) != '../wootc-observer.service':
                    raise ValueError('activation label parent/link identity changed')
                anchored = f'/proc/self/fd/{fd}/{path.name}'
                os.setxattr(anchored, 'security.selinux', context.encode('ascii') + b'\x00', follow_symlinks=False)
                value = os.getxattr(anchored, 'security.selinux', follow_symlinks=False)
                after_parent = path.parent.lstat()
                if (after_parent.st_dev, after_parent.st_ino) != (parent.st_dev, parent.st_ino) or os.readlink(path) != '../wootc-observer.service':
                    raise ValueError('activation label parent/link changed during write')
            finally:
                os.close(fd)
        else:
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
            if record['kind'] == 'directory':
                flags |= os.O_DIRECTORY
            fd = os.open(path, flags)
            try:
                opened = os.fstat(fd)
                if not shape(opened.st_mode) or opened.st_uid != 0 or opened.st_mode & 0o022 or (opened.st_dev, opened.st_ino) != (record['device'], record['inode']):
                    raise ValueError('opened label inode differs')
                os.setxattr(fd, 'security.selinux', context.encode('ascii') + b'\x00')
                value = os.getxattr(fd, 'security.selinux')
                final = os.fstat(fd)
                if not shape(final.st_mode) or final.st_uid != 0 or final.st_mode & 0o022 or (final.st_dev, final.st_ino) != (record['device'], record['inode']):
                    raise ValueError('retained label descriptor identity changed')
                os.fsync(fd)
            finally:
                os.close(fd)
        after = path.lstat()
        if len(value) > 4096 or value.rstrip(b'\x00').decode('ascii') != context or not shape(after.st_mode) or after.st_uid != 0 or (after.st_dev, after.st_ino) != (record['device'], record['inode']):
            raise ValueError('owned target label readback differs')
        observed[str(path)] = context
    if ACTIVATION not in observed or not set(map(str, FILES)).issubset(observed):
        raise ValueError('complete observer/unit/activation label proof required')
    return {'configuredMode': mode, 'labelsRequired': True, 'labels': observed}
