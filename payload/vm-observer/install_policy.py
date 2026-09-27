"""Read-only selected deployment policy preflight; no installation entrypoint yet."""
import configparser
import os
from pathlib import Path
import stat
import tomllib

MAX = 128 * 1024


def protected_read(path):
    path = Path(path)
    for item in (path, *path.parents):
        facts = item.lstat()
        if facts.st_uid != 0 or facts.st_mode & 0o022 or stat.S_ISLNK(facts.st_mode):
            raise ValueError('unprotected or linked policy dependency')
        if item != path and not stat.S_ISDIR(facts.st_mode):
            raise ValueError('policy ancestor is not a directory')
    facts = path.lstat()
    if not stat.S_ISREG(facts.st_mode) or facts.st_size > MAX:
        raise ValueError('policy dependency is not a bounded regular file')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        opened = os.fstat(fd)
        if (facts.st_dev, facts.st_ino) != (opened.st_dev, opened.st_ino):
            raise ValueError('policy inode changed before read')
        value = bytearray()
        while len(value) <= MAX:
            part = os.read(fd, min(4096, MAX + 1 - len(value)))
            if not part:
                break
            value.extend(part)
    finally:
        os.close(fd)
    if len(value) > MAX:
        raise ValueError('policy dependency grew beyond bound')
    after = path.lstat()
    if (facts.st_dev, facts.st_ino, facts.st_mtime_ns, facts.st_size) != (after.st_dev, after.st_ino, after.st_mtime_ns, after.st_size):
        raise ValueError('policy changed during observation')
    return bytes(value)


def read_optional(path):
    # lexists ensures dangling links refuse rather than becoming default policy.
    return protected_read(path) if os.path.lexists(path) else None


def validate_persistence(deployment, installed_boot_entries):
    """Inputs are owned mounted deployment and measured installed BLS contents.

    This checks configuration only. Actual selected disk/mount relationships and
    authenticated bundle verification must precede installation separately.
    """
    deployment = Path(deployment)
    for item in (deployment, *deployment.parents):
        facts = item.lstat()
        if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != 0 or facts.st_mode & 0o022:
            raise ValueError('unprotected or linked deployment namespace')
    if type(installed_boot_entries) is not list or not installed_boot_entries or len(installed_boot_entries) > 128:
        raise ValueError('installed boot arguments are required')
    installed_boot_entries = list(installed_boot_entries)
    for relative in ('usr/lib/composefs/setup-root-conf.toml', 'usr/lib/bootc/setup-root-conf.toml'):
        raw = read_optional(deployment / relative)
        if raw is None:
            continue
        conf = tomllib.loads(raw.decode('utf-8'))
        for section in ('root', 'etc', 'var'):
            value = conf.get(section, {})
            if type(value) is not dict:
                raise ValueError('invalid filesystem policy section')
            if 'transient' in value and type(value['transient']) is not bool:
                raise ValueError('invalid transient policy type')
            if value.get('transient', False):
                raise ValueError('transient filesystem policy unsupported')
        if conf.get('etc', {}).get('mount', 'bind') not in ('bind', 'overlay') or conf.get('var', {}).get('mount', 'bind') != 'bind':
            raise ValueError('persistent etc and var are required')
    raw = read_optional(deployment / 'usr/lib/ostree/prepare-root.conf')
    if raw is not None:
        conf = configparser.ConfigParser(interpolation=None, strict=True)
        conf.read_string(raw.decode('utf-8'))
        for section in ('root', 'etc'):
            if conf.has_option(section, 'transient') and conf.getboolean(section, 'transient'):
                raise ValueError('transient OSTree policy unsupported')
    kargs = deployment / 'usr/lib/bootc/kargs.d'
    if os.path.lexists(kargs):
        facts = kargs.lstat()
        if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != 0 or facts.st_mode & 0o022:
            raise ValueError('unprotected karg namespace')
        paths = sorted(kargs.iterdir())
        if len(paths) > 128:
            raise ValueError('karg inventory exceeds bound')
        for file in paths:
            if file.suffix != '.toml':
                raise ValueError('unknown karg inventory entry')
            conf = tomllib.loads(protected_read(file).decode('utf-8'))
            args = conf.get('kargs')
            if type(args) is not list or any(type(arg) is not str for arg in args):
                raise ValueError('karg policy is not observed')
            installed_boot_entries += [' '.join(args)]
    if type(installed_boot_entries) is not list or not installed_boot_entries or len(installed_boot_entries) > 128:
        raise ValueError('installed boot arguments are required')
    for entry in installed_boot_entries:
        if type(entry) is not str or len(entry) > MAX:
            raise ValueError('invalid installed boot argument observation')
        for token in entry.split():
            if token.startswith(('systemd.volatile=', 'rd.systemd.volatile=')) and token not in ('systemd.volatile=no', 'rd.systemd.volatile=no'):
                raise ValueError('volatile installed boot unsupported')
    return {'etcPersistent': True, 'varPersistent': True, 'configurationOnly': True}
