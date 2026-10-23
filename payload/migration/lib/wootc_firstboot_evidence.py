#!/usr/bin/python3
"""Measure the installed system's first boot for installed-linux-boot.json.

Contract: docs/borrowed-from-libertix.md section 3. Every field is read from
the running boot (EFI variables, the kernel command line, the mount table,
loop devices, bootc), never from a record an earlier step left behind.
Windows cross-checks the result before it reports the installation healthy,
so an observation that cannot be made is a failure here, not a guess: the
caller then writes nothing and the unit retries on the next boot.

Usage: wootc_firstboot_evidence.py --host /run/initramfs/wootc-host
Prints one JSON object on stdout.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wootc_boot_identity import (EFI_GUID, boot_argument, booted_image,  # noqa: E402
                                 bootc_status, command, decode_boot_option,
                                 decode_efibootmgr, loop_backing_name,
                                 loop_backs_file, mount_rows, read, require)

SCHEMA = 1
ROOT_DISK = '/wootc/disks/root.disk'
NTFS_TYPES = ('ntfs3', 'fuseblk', 'ntfs')
BITLOCKER_MOUNT = '/run/wootc/bitlk-tmp'
MAX_FAILED_UNITS = 32
UNIT_NAME = re.compile(r'[A-Za-z0-9@._:\\-]{1,128}')
DIGEST = re.compile(r'sha256:[0-9a-f]{64}')


def text_field(value, name, limit=512):
    require(isinstance(value, str) and value and len(value) <= limit and
            not any(ord(c) < 0x20 or ord(c) == 0x7f for c in value), 'invalid ' + name)
    return value


# One rule for every reader of the root.disk boot arguments.
cmdline_argument = boot_argument


def boot_current(efivars, run=command):
    """BootCurrent decoded to its load option; efibootmgr when efivarfs fails.

    The boot entry is reported, not trusted: Windows does not gate on it, so a
    firmware whose load option cannot be decoded still records its number.
    """
    number = None
    try:
        current = read(efivars / ('BootCurrent-' + EFI_GUID), 6)
        require(len(current) == 6, 'invalid BootCurrent length')
        number = struct.unpack_from('<H', current, 4)[0]
        option = read(efivars / ('Boot%04X-' % number + EFI_GUID))
        return dict(bootNumber='%04X' % number, source='efivarfs', **decode_boot_option(option))
    except (OSError, ValueError, UnicodeDecodeError):
        pass
    try:
        return dict(decode_efibootmgr(run('efibootmgr', '-v')), source='efibootmgr')
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    result = {'source': 'unavailable'}
    if number is not None:
        result['bootNumber'] = '%04X' % number
    return result


def secure_boot(efivars):
    try:
        data = read(efivars / ('SecureBoot-' + EFI_GUID), 5)
    except OSError:
        return False  # no variable: firmware is not enforcing Secure Boot
    require(len(data) == 5 and data[4] in (0, 1), 'invalid SecureBoot variable')
    return data[4] == 1


def loop_attached(disk, sysfs):
    """The loop device backed by this root.disk, by the rule the ESP
    controller also uses (wootc_boot_identity.loop_backs_file)."""
    seen = []
    for backing in sorted((sysfs / 'block').glob('loop*/loop/backing_file')):
        loop = backing.parent.parent
        seen.append('%s=%s' % (loop.name, loop_backing_name(loop)))
        if loop_backs_file(loop, disk, ROOT_DISK):
            return loop.name
    raise ValueError('root.disk is not attached as a loop device (loop backing files: %s)'
                     % (', '.join(seen) or 'none'))


def root_disk(tokens, host, rows, sysfs, run=command):
    path = cmdline_argument(tokens, 'loop')
    host_uuid = cmdline_argument(tokens, 'wootc.host_uuid').upper()
    require(path == ROOT_DISK and re.fullmatch('[0-9A-F]{16}', host_uuid),
            'unsupported root.disk identity on the kernel command line')
    mounts = [row for row in rows if row['target'] == str(host)]
    # ntfs3 in the kernel, or ntfs-3g/lowntfs-3g over FUSE (fuseblk, which
    # mountinfo may print with the driver as a subtype).
    require(len(mounts) == 1 and mounts[0]['type'].split('.', 1)[0] in NTFS_TYPES,
            'the Windows host is not one NTFS mount')
    observed = run('blkid', '-s', 'UUID', '-o', 'value', mounts[0]['source']).strip().upper()
    require(observed == host_uuid, 'mounted NTFS UUID differs from the kernel command line')
    disk = host / path.lstrip('/')
    require(disk.is_file() and not disk.is_symlink(), 'root.disk is absent from the host volume')
    loop_attached(disk, sysfs)
    return {'path': path, 'hostUuid': observed}


def bridge(host, rows):
    """User Data Bridge as the mount table shows it, after wootc-passthrough."""
    devices = {row['device'] for row in rows if row['target'] in (str(host), BITLOCKER_MOUNT)}
    targets = {}
    for row in rows:
        # /home is a link to /var/home on ostree: one folder, two spellings.
        target = row['target'][len('/var'):] if row['target'].startswith('/var/home/') else row['target']
        match = re.fullmatch(r'/home/([^/]+)/.+', target)
        if match and row['device'] in devices:
            targets[target] = match[1]
    return {'boundFolders': len(targets), 'matchedUsers': len(set(targets.values())),
            'bitlockerUnlocked': any(row['target'] == BITLOCKER_MOUNT for row in rows)}


def failed_units(run=command):
    try:
        output = run('systemctl', 'list-units', '--failed', '--plain', '--no-legend', '--no-pager')
    except (OSError, subprocess.SubprocessError):
        return []
    names = [line.split()[0] for line in output.splitlines() if line.strip()]
    return [name for name in names if UNIT_NAME.fullmatch(name)][:MAX_FAILED_UNITS]


def image(etc, run=command):
    # The same reading of bootc as the ESP controller (wootc_boot_identity),
    # except that here no bootc is a refusal too: this record is for bootc
    # installs only.
    try:
        ref, digest = booted_image(bootc_status(run))
    except (OSError, ValueError) as error:
        raise ValueError('cannot measure the booted bootc image: %s' % error) from error
    text_field(ref, 'booted image reference')
    require(DIGEST.fullmatch(digest), 'invalid booted image digest')
    result = {'ref': ref, 'digest': digest}
    # The deployer may install a locally derived image; the reference the
    # user chose is what it recorded for day-2 updates.
    try:
        conf = read(etc / 'wootc/host-esp.conf', 65536).decode('utf-8')
    except (OSError, ValueError, UnicodeDecodeError):
        conf = ''
    sources = re.findall(r'^SOURCE_IMAGE_REF=(\S+)\s*$', conf, re.M)
    if len(sources) == 1:
        result['sourceRef'] = text_field(sources[0], 'source image reference')
    return result


def collect(host, proc=Path('/proc'), sysfs=Path('/sys'), etc=Path('/etc'), run=command, now=None):
    host = Path(host)
    tokens = read(proc / 'cmdline').decode('utf-8').split()
    rows = mount_rows(proc)
    boot_id = read(proc / 'sys/kernel/random/boot_id', 64).decode().strip()
    require(str(uuid.UUID(boot_id)) == boot_id, 'invalid kernel boot ID')
    kernel = text_field(read(proc / 'sys/kernel/osrelease', 256).decode().strip(), 'kernel release', 128)
    efivars = sysfs / 'firmware/efi/efivars'
    now = now or datetime.datetime.now(datetime.timezone.utc)
    return {
        'schema': SCHEMA,
        'state': 'healthy',
        'phaseId': 'firstboot-evidence',
        # One record per installation: the unit never rewrites an existing
        # file, and a reader can tell which boot produced this one.
        'sequence': 1,
        'bootId': boot_id,
        'kernel': kernel,
        'image': image(etc, run),
        'bootCurrent': boot_current(efivars, run),
        'rootDisk': root_disk(tokens, host, rows, sysfs, run),
        'bridge': bridge(host, rows),
        'secureBoot': secure_boot(efivars),
        'failedUnits': failed_units(run),
        'writtenAt': now.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'updatedBy': 'wootc-firstboot',
    }


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', required=True)
    parser.add_argument('--proc', default='/proc')
    parser.add_argument('--sys', default='/sys')
    parser.add_argument('--etc', default='/etc')
    args = parser.parse_args(argv)
    try:
        record = collect(args.host, Path(args.proc), Path(args.sys), Path(args.etc))
    except (OSError, ValueError, UnicodeDecodeError) as error:
        print('first-boot evidence unavailable: %s' % error, file=sys.stderr)
        return 1
    print(json.dumps(record, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
