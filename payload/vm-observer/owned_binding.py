"""Dormant owned read-only bundle bind lifecycle; no builder hook.

All arguments originate in reviewed authenticated installer preflight. This
module is never imported from guest requests. Tool calls use the observer's
bounded owned-child runner, including cleanup with its own two-second bound.
"""
from contextlib import contextmanager
import os
from pathlib import Path
import re
import stat
import time

MAX_MOUNTS = 2 * 1024 * 1024


def protected_directory(path):
    for item in (path, *path.parents):
        facts = item.lstat()
        if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != 0 or facts.st_mode & 0o022:
            raise ValueError('bind namespace ancestor is unprotected or linked')


def identity(path):
    value = path.lstat()
    return value.st_dev, value.st_ino


def mount_present(namespace):
    # Complete successful bounded kernel inventory, not an ignored findmnt rc.
    with open('/proc/self/mountinfo', 'rb') as stream:
        raw = stream.read(MAX_MOUNTS + 1)
    if len(raw) > MAX_MOUNTS:
        raise ValueError('mount inventory exceeds bound')
    value = raw.decode('ascii', errors='strict')
    rows = value.splitlines()
    if len(rows) > 4096:
        raise ValueError('mount inventory count exceeds bound')
    matches = 0
    for row in rows:
        fields = row.split(' ')
        if len(fields) < 10 or '-' not in fields or not re.fullmatch(r'[0-9]+:[0-9]+', fields[2]):
            raise ValueError('kernel mount inventory malformed')
        target = fields[4]
        # Kernel escaping cannot identify this fixed plain namespace.
        if target == str(namespace):
            matches += 1
    if matches > 1:
        raise ValueError('ambiguous namespace mount stack')
    return matches == 1


def exact_source_subtree(source, row):
    """Derive the later bind SOURCE from the observed authenticated source row."""
    if type(row) is not dict or set(row) != {'target', 'source', 'maj:min'} or any(type(v) is not str or not v for v in row.values()):
        raise ValueError('retained source mount identity unavailable')
    source = Path(source)
    target = Path(row['target'])
    if not target.is_absolute() or '..' in target.parts or '\\' in row['target'] or not re.fullmatch(r'[0-9]+:[0-9]+', row['maj:min']):
        raise ValueError('source mount identity malformed')
    relative = source.relative_to(target)
    match = re.fullmatch(r'([^\[\]\\\s]+)(?:\[(/[^\[\]\\\s]*)\])?', row['source'])
    if not match:
        raise ValueError('source subtree observation unsupported')
    root = Path(match[2] or '/')
    if '..' in root.parts or '.' in root.parts:
        raise ValueError('source subtree is not canonical')
    return match[1] + '[' + str(root / relative) + ']'


@contextmanager
def readonly_bundle(source, deployment, source_mount_row, tools, owned_runner, deadline):
    """Yield an owned mounted path plus independently derived expected SOURCE.

    The caller must run input_binding.verify_bound_input and interpreter/policy
    preflight before any invocation. Cleanup never deletes source evidence or
    removes a foreign/changed namespace, and never masks cleanup failure.
    """
    source, deployment = Path(source), Path(deployment)
    protected_directory(source)
    protected_directory(deployment)
    if set(tools) != {'mount', 'umount'} or len(set(map(str, tools.values()))) != 2:
        raise ValueError('fixed protected bind tools unavailable')
    namespace = deployment / 'run/wootc-observer-input'
    protected_directory(namespace.parent)
    expected_source = exact_source_subtree(source, source_mount_row)
    source_identity = identity(source)
    if os.path.lexists(namespace) or mount_present(namespace):
        raise ValueError('private input namespace already exists')
    namespace.mkdir(mode=0o700)
    own_identity = identity(namespace)
    protected_directory(namespace)
    try:
        owned_runner([str(tools['mount']), '--bind', str(source), str(namespace)], deadline)
        if not mount_present(namespace) or identity(namespace) != source_identity:
            raise ValueError('successful bind command lacks current source identity')
        owned_runner([str(tools['mount']), '-o', 'remount,bind,ro', str(namespace)], deadline)
        if not mount_present(namespace) or identity(namespace) != source_identity:
            raise ValueError('read-only remount lacks current source identity')
        yield namespace, expected_source
    finally:
        present = mount_present(namespace)
        current = identity(namespace)
        if present:
            if current != source_identity:
                raise ValueError('cleanup refuses foreign mounted source')
            owned_runner([str(tools['umount']), str(namespace)], time.monotonic() + 2)
            if mount_present(namespace):
                raise ValueError('unmount command lacks current kernel readback')
            current = identity(namespace)
        if current != own_identity:
            raise ValueError('cleanup refuses changed owned namespace inode')
        protected_directory(namespace)
        namespace.rmdir()
