"""Fixed installer command consumers; never exposed by the guest protocol."""
import json
import re
from pathlib import Path

FILES = {'/var/usrlocal/lib/wootc/observer/boot_probe.py', '/var/usrlocal/lib/wootc/observer/wootc_ancestry.py', '/etc/systemd/system/wootc-observer.service'}
OUTPUT = 'TARGET,SOURCE,FSTYPE,OPTIONS,MAJ:MIN'


def executor(owned_runner, protected_tools, deadline):
    """owned_runner is the reviewed bounded _run_owned, not subprocess.run.

    protected_tools comes from fixed target tool preflight with inode/hash
    records. No request accepts a tool registry, argv, path or operation.
    """
    if set(protected_tools) != {'findmnt', 'matchpathcon', 'setfiles'} or len(set(map(str, protected_tools.values()))) != 3:
        raise ValueError('fixed protected installer tools unavailable')
    names = {str(value): name for name, value in protected_tools.items()}
    def execute(argv):
        if type(argv) is not list or not argv or any(type(arg) is not str for arg in argv):
            raise ValueError('installer argv is not fixed')
        name = names.get(argv[0])
        valid = False
        if name == 'matchpathcon':
            valid = len(argv) == 3 and argv[1] == '-n' and argv[2] in FILES
        elif name == 'setfiles':
            valid = len(argv) == 6 and argv[1] == '-F' and re.fullmatch(r'/etc/selinux/[A-Za-z0-9_-]{1,64}/contexts/files/file_contexts', argv[2]) and set(argv[3:]) == FILES
        elif name == 'findmnt':
            valid = len(argv) == 6 and argv[1:5] == ['--json', '--output', OUTPUT, '--mountpoint'] and argv[5] in {'/var', '/run/wootc-observer-input'}
        if not valid:
            raise ValueError('installer command outside reviewed scope')
        # The same actual exit/deadline/overflow/reap guard as the observer.
        return owned_runner(argv, deadline)
    return execute


def unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('duplicate mount observation')
        value[key] = item
    return value


def observed_mount(execute, findmnt, target, expected_major, readonly):
    raw = execute([str(findmnt), '--json', '--output', OUTPUT, '--mountpoint', target])
    if type(raw) is not str or not raw or len(raw.encode()) > 128 * 1024:
        raise ValueError('mount command observation unavailable')
    try:
        value = json.loads(raw, object_pairs_hook=unique)
    except RecursionError as error:
        raise ValueError('mount observation nesting exceeds bound') from error
    if type(value) is not dict or set(value) != {'filesystems'} or type(value['filesystems']) is not list or len(value['filesystems']) != 1:
        raise ValueError('unique actual mount row required')
    row = value['filesystems'][0]
    if type(row) is not dict or set(row) != {'target','source','fstype','options','maj:min'} or any(type(item) is not str or not item for item in row.values()):
        raise ValueError('mount row is not typed')
    if row['target'] != target or not re.fullmatch(r'[0-9]+:[0-9]+', expected_major) or row['maj:min'] != expected_major:
        raise ValueError('actual mount target/source device identity differs')
    allowed = {'rootfs', 'tmpfs', 'ramfs', 'ext4', 'xfs', 'btrfs'} if readonly else {'ext4', 'xfs', 'btrfs'}
    if row['fstype'] not in allowed:
        raise ValueError('actual source filesystem is unsupported')
    options = row['options'].split(',')
    if (readonly and ('ro' not in options or 'rw' in options)) or (not readonly and ('rw' not in options or 'ro' in options)):
        raise ValueError('actual mount mode differs')
    return row
