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
