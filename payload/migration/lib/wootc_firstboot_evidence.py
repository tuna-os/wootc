#!/usr/bin/python3
"""Measure the installed system's first boot for installed-linux-boot.json.

Contract: docs/borrowed-from-libertix.md section 3. Every field is read from
the running boot (EFI variables, the kernel command line, the mount table,
loop devices, bootc), never from a record an earlier step left behind.
Windows cross-checks the result before it reports the installation healthy,
so an observation that cannot be made is a failure here, not a guess: the
caller then writes nothing and the unit retries on the next boot.

The measurement is also bound to this installation attempt: Windows writes
\\wootc\\install\\installation.json when it stages the boot (a fresh
installation ID, the arm time, the staged ESP and loader, the host volume, the
selected image), and a boot that predates it, ran from another ESP or loader,
another volume or another image is refused here as well as on Windows.

Usage: wootc_firstboot_evidence.py --host /run/initramfs/wootc-host
       wootc_firstboot_evidence.py --publish-summary RECORD [--summary-dir DIR]
The first prints one JSON object on stdout. The second publishes the few
facts the local control panels show (kernel, image, bridge counts) to a
root-owned, world-readable summary; the installation ID, paths and profile
mappings stay on the protected NTFS tree.
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
import tempfile
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wootc_boot_identity import (EFI_GUID, backed_by_root_disk, boot_argument,  # noqa: E402
                                 booted_image, bootc_status, command,
                                 decode_boot_option, decode_efibootmgr,
                                 loop_backing_name, loop_backs_file, mount_rows,
                                 read, require)

SCHEMA = 1
ROOT_DISK = '/wootc/disks/root.disk'
NTFS_TYPES = ('ntfs3', 'fuseblk', 'ntfs')
BITLOCKER_MOUNT = '/run/wootc/bitlk-tmp'
MAX_FAILED_UNITS = 32
UNIT_NAME = re.compile(r'[A-Za-z0-9@._:\\-]{1,128}')
DIGEST = re.compile(r'sha256:[0-9a-f]{64}')
INSTALLATION = 'wootc/install/installation.json'
INSTALLATION_ID = re.compile(r'[0-9a-f]{32}')
BRIDGE_UNITS = ('wootc-host-bind.service', 'wootc-passthrough.service')
MAX_RECORD = 65536
SUMMARY_NAME = 'installed-linux-boot-summary.json'


def text_field(value, name, limit=512):
    require(isinstance(value, str) and value and len(value) <= limit and
            not any(ord(c) < 0x20 or ord(c) == 0x7f for c in value), 'invalid ' + name)
    return value


def normalize_image(value):
    return value[len('docker://'):] if value.startswith('docker://') else value


def parse_time(value, name):
    text_field(value, name, 64)
    moment = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(moment.tzinfo is not None, name + ' must include a time zone')
    return moment


def installation(host, proc, now):
    """This installation attempt as Windows staged it.

    The boot being measured must have started after Windows armed it: a
    previous installation's healthy boot cannot vouch for a new attempt.
    """
    try:
        plan = json.loads(read(Path(host) / INSTALLATION, MAX_RECORD).decode('utf-8-sig'))
    except (OSError, ValueError, UnicodeDecodeError) as error:
        raise ValueError('missing installation identity: %s' % error) from error
    require(isinstance(plan, dict) and plan.get('schemaVersion') == 1 and
            isinstance(plan.get('installationId'), str) and
            INSTALLATION_ID.fullmatch(plan['installationId']), 'missing installation identity')
    for name in ('imageRef', 'espPartitionGuid', 'loaderPath', 'hostUuid', 'rootDiskPath'):
        text_field(plan.get(name), 'installation ' + name)
    armed = parse_time(plan.get('armedAt'), 'installation armedAt')
    require(armed <= now, 'installation is armed in the future')
    uptime = float(read(proc / 'uptime', 256).decode().split()[0])
    require(uptime >= 0 and now - datetime.timedelta(seconds=uptime) >= armed,
            'current Linux boot predates this installation attempt')
    return plan


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


def root_disk(tokens, host, rows, sysfs, run=command, plan=None):
    path = cmdline_argument(tokens, 'loop')
    host_uuid = cmdline_argument(tokens, 'wootc.host_uuid').upper()
    require(path == ROOT_DISK and re.fullmatch('[0-9A-F]{16}', host_uuid),
            'unsupported root.disk identity on the kernel command line')
    if plan is not None:
        require(path == plan['rootDiskPath'], 'root.disk kernel argument does not match installation')
        require(host_uuid == plan['hostUuid'].upper(), 'host UUID kernel argument does not match installation')
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
    # Attached is not booted: the installed sysroot itself must sit on this
    # root.disk, by the rule the ESP controller uses.
    sysroots = [row for row in rows if row['target'] == '/sysroot']
    require(len(sysroots) == 1, 'missing installed sysroot mount')
    require(backed_by_root_disk(sysfs / 'dev/block' / sysroots[0]['device'], disk, path),
            'installed sysroot is not this root.disk')
    return {'path': path, 'hostUuid': observed}


def bitlocker_unlocked(rows, run=command):
    """True only for C: opened by the bridge as an actual BitLocker mapping."""
    mounts = [row for row in rows if row['target'] == BITLOCKER_MOUNT]
    if not mounts:
        return False
    require(len(mounts) == 1, 'the unlocked BitLocker volume is mounted more than once')
    source = mounts[0]['source']
    require(source.startswith('/dev/mapper/wootc-bitlk-'), 'unexpected BitLocker profile source')
    try:
        status = run('cryptsetup', 'status', source)
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError('cannot confirm the BitLocker mapping: %s' % error) from error
    require(re.search(r'^\s*type:\s*bitlk\b', status, re.I | re.M),
            'profile source is not an unlocked BitLocker volume')
    return True


def bridge(host, rows, run=command):
    """User Data Bridge as the mount table shows it, after wootc-passthrough."""
    roots = {row['device']: row['target'] for row in rows if row['target'] in (str(host), BITLOCKER_MOUNT)}
    targets = {}
    for row in rows:
        # /home is a link to /var/home on ostree: one folder, two spellings.
        target = row['target'][len('/var'):] if row['target'].startswith('/var/home/') else row['target']
        match = re.fullmatch(r'/home/([^/]+)/.+', target)
        if match and row['device'] in roots:
            # A bind exposes one folder, never the whole Windows volume or
            # the installer's own records on it.
            require(row['root'] != '/', 'bridge exposes the whole Windows volume')
            # \wootc at the volume root holds the installer's records. A
            # Windows profile may itself be named wootc (the E2E user is).
            require(row['root'].split('/')[1].lower() != 'wootc', 'bridge exposes installer metadata')
            targets[target] = {'source': roots[row['device']].rstrip('/') + row['root'],
                               'target': target, 'user': match[1]}
    bindings = [targets[target] for target in sorted(targets)]
    return {'boundFolders': len(bindings), 'matchedUsers': len({b['user'] for b in bindings}),
            'bitlockerUnlocked': bitlocker_unlocked(rows, run), 'bindings': bindings}


def bridge_units(run=command):
    """The bridge's own units finished; the mount table alone cannot say so."""
    for unit in BRIDGE_UNITS:
        try:
            output = run('systemctl', 'show', unit, '--property=ActiveState',
                         '--property=SubState', '--property=Result')
        except (OSError, subprocess.SubprocessError) as error:
            raise ValueError('cannot read %s: %s' % (unit, error)) from error
        state = dict(line.split('=', 1) for line in output.splitlines() if '=' in line)
        require(state == {'ActiveState': 'active', 'SubState': 'exited', 'Result': 'success'},
                'required bridge unit did not complete: ' + unit)


def failed_units(run=command):
    try:
        output = run('systemctl', 'list-units', '--failed', '--plain', '--no-legend', '--no-pager')
    except (OSError, subprocess.SubprocessError):
        return []
    names = [line.split()[0] for line in output.splitlines() if line.strip()]
    return [name for name in names if UNIT_NAME.fullmatch(name)][:MAX_FAILED_UNITS]


def image(etc, run=command, plan=None):
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
    if plan is not None:
        require('sourceRef' in result and
                normalize_image(result['sourceRef']) == normalize_image(plan['imageRef']),
                'installed source image does not match installation')
        # The image the deployer passed to bootc (possibly its local
        # NTFS-injected derivative) is the one that must be booted.
        try:
            installed = text_field(read(etc / 'wootc/installed-image-ref', 4096).decode('utf-8').strip(),
                                   'installed image reference')
        except (OSError, UnicodeDecodeError) as error:
            raise ValueError('missing installed image reference: %s' % error) from error
        require(normalize_image(ref) == normalize_image(installed), 'booted image does not match installed image')
        if '@sha256:' in installed:
            require(installed.rsplit('@', 1)[1] == digest, 'booted image digest differs from pinned install')
    return result


def check_boot_current(current, plan):
    """A decoded boot entry must be the staged one. An undecodable entry is
    still reported, not trusted (see boot_current)."""
    if 'espPartitionGuid' in current or 'loaderPath' in current:
        require(current.get('espPartitionGuid', '').lower() == plan['espPartitionGuid'].lower() and
                current.get('loaderPath', '').lower() == plan['loaderPath'].replace('/', '\\').lower(),
                'BootCurrent does not match the staged ESP and loader')
    return current


def collect(host, proc=Path('/proc'), sysfs=Path('/sys'), etc=Path('/etc'), run=command, now=None):
    host = Path(host)
    now = now or datetime.datetime.now(datetime.timezone.utc)
    plan = installation(host, proc, now)
    tokens = read(proc / 'cmdline').decode('utf-8').split()
    rows = mount_rows(proc)
    boot_id = read(proc / 'sys/kernel/random/boot_id', 64).decode().strip()
    require(str(uuid.UUID(boot_id)) == boot_id, 'invalid kernel boot ID')
    kernel = text_field(read(proc / 'sys/kernel/osrelease', 256).decode().strip(), 'kernel release', 128)
    efivars = sysfs / 'firmware/efi/efivars'
    bridge_units(run)
    record = {
        'schema': SCHEMA,
        'installationId': plan['installationId'],
        'state': 'healthy',
        'phaseId': 'firstboot-evidence',
        # One record per installation: the unit never rewrites an existing
        # file, and a reader can tell which boot produced this one.
        'sequence': 1,
        'bootId': boot_id,
        'kernel': kernel,
        'image': image(etc, run, plan),
        'bootCurrent': check_boot_current(boot_current(efivars, run), plan),
        'rootDisk': root_disk(tokens, host, rows, sysfs, run, plan),
        'bridge': bridge(host, rows, run),
        'secureBoot': secure_boot(efivars),
        'failedUnits': failed_units(run),
        'writtenAt': now.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'updatedBy': 'wootc-firstboot',
    }
    require(len(json.dumps(record, indent=2).encode()) <= MAX_RECORD, 'first-boot evidence exceeds 64 KiB')
    return record


def publish_summary(evidence, directory):
    """Write the control panels' public summary of a recorded first boot."""
    record = json.loads(read(evidence, MAX_RECORD).decode('utf-8-sig'))
    require(isinstance(record, dict) and record.get('state') == 'healthy' and
            record.get('updatedBy') == 'wootc-firstboot', 'not a first-boot evidence record')
    image_record = record['image']
    summary = {'kernel': record['kernel'],
               'sourceImageRef': image_record.get('sourceRef') or image_record['ref'],
               'imageDigest': image_record['digest'], 'writtenAt': record['writtenAt'],
               'boundFolders': record['bridge']['boundFolders'],
               'matchedUsers': record['bridge']['matchedUsers']}
    directory = Path(directory)
    require(not directory.is_symlink(), 'summary directory cannot be a symlink')
    directory.mkdir(parents=True, exist_ok=True, mode=0o755)
    info = directory.stat()
    require(info.st_uid == os.geteuid() and not info.st_mode & 0o022,
            'summary directory must be owned by the service and not writable by other users')
    fd, temporary = tempfile.mkstemp(dir=directory, prefix='.firstboot-summary-')
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), 0o644)
            json.dump(summary, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, directory / SUMMARY_NAME)
        directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--host')
    parser.add_argument('--proc', default='/proc')
    parser.add_argument('--sys', default='/sys')
    parser.add_argument('--etc', default='/etc')
    parser.add_argument('--publish-summary', type=Path)
    parser.add_argument('--summary-dir', type=Path, default=Path('/var/lib/wootc'))
    args = parser.parse_args(argv)
    if args.publish_summary is not None:
        try:
            publish_summary(args.publish_summary, args.summary_dir)
        except (OSError, ValueError, KeyError, TypeError, UnicodeDecodeError) as error:
            print('first-boot summary refused: %s' % error, file=sys.stderr)
            return 1
        return 0
    if not args.host:
        parser.error('--host is required for collection')
    try:
        record = collect(args.host, Path(args.proc), Path(args.sys), Path(args.etc))
    except (OSError, ValueError, KeyError, TypeError, UnicodeDecodeError) as error:
        print('first-boot evidence unavailable: %s' % error, file=sys.stderr)
        return 1
    print(json.dumps(record, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
