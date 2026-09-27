#!/usr/bin/python3
"""Collect installed Linux facts. Missing or inconsistent boot identity is fatal."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import sys
import uuid

EFI_GUID = '8be4df61-93ca-11d2-aa0d-00e098032b8c'
FOLDERS = {'Documents', 'Pictures', 'Downloads', 'Music', 'Videos', 'Desktop'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path, limit=1048576):
    path = Path(path)
    require(not path.is_symlink(), 'refusing symlink source: ' + str(path))
    with path.open('rb') as stream:
        data = stream.read(limit + 1)
    require(len(data) <= limit, 'oversized source: ' + str(path))
    return data


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True,
                          timeout=30).stdout


def decode_boot_option(data):
    """Decode EFI_LOAD_OPTION after efivarfs's four attribute bytes."""
    require(len(data) >= 12, 'truncated Boot option')
    attributes, path_length = struct.unpack_from('<IH', data, 4)
    require(attributes & 1, 'Boot option is not active')
    pos = 10
    while pos + 2 <= len(data) and data[pos:pos + 2] != b'\0\0':
        pos += 2
    require(pos + 2 <= len(data), 'unterminated Boot description')
    data[10:pos].decode('utf-16-le', errors='strict')
    pos += 2
    end = pos + path_length
    require(path_length >= 4 and end <= len(data), 'truncated EFI device path')
    guid, loader, terminated = None, '', False
    while pos < end:
        require(pos + 4 <= end, 'truncated EFI node header')
        kind, subtype, size = struct.unpack_from('<BBH', data, pos)
        require(size >= 4 and pos + size <= end, 'invalid EFI node length')
        node = data[pos:pos + size]
        if (kind, subtype) == (4, 1):
            require(size == 42 and node[40:42] == bytes([2, 2]),
                    'BootCurrent must name a GPT GUID partition')
            require(guid is None, 'ambiguous EFI partition')
            guid = str(uuid.UUID(bytes_le=node[24:40]))
            require(guid != str(uuid.UUID(int=0)), 'empty EFI partition GUID')
        elif (kind, subtype) == (4, 4):
            require(size >= 8 and (size - 4) % 2 == 0 and node[-2:] == b'\0\0',
                    'invalid EFI file path')
            part = node[4:-2].decode('utf-16-le', errors='strict')
            require('\0' not in part, 'embedded NUL in EFI file path')
            loader += part
        elif kind == 0x7f:
            require(subtype == 0xff and size == 4 and pos + size == end,
                    'invalid EFI device path terminator')
            terminated = True
        pos += size
    require(terminated and guid and loader.startswith('\\EFI\\') and
            '..' not in loader.split('\\'), 'incomplete EFI boot identity')
    return {'espPartitionGuid': guid, 'loaderPath': loader}


def decode_efibootmgr(output):
    """Fallback for inaccessible EFI files; ambiguous tool output is refused."""
    current = re.findall(r'^BootCurrent:\s*([0-9A-Fa-f]{4})\s*$', output, re.M)
    require(len(current) == 1, 'efibootmgr lacks one BootCurrent')
    number = current[0].upper()
    entries = re.findall(r'^Boot' + number + r'(?:\*|\s).*$', output, re.M | re.I)
    require(len(entries) == 1 and entries[0][8:9] == '*',
            'efibootmgr lacks one active current Boot option')
    entry = entries[0]
    require(entry.count('HD(') == entry.count('File(') == 1,
            'ambiguous efibootmgr device path')
    partition = re.search(r'HD\(([1-9][0-9]*),GPT,([0-9a-fA-F-]{36}),'
                          r'(0x[0-9a-fA-F]+|[0-9]+),(0x[0-9a-fA-F]+|[0-9]+)\)', entry)
    loader = re.search(r'File\(([^()]+)\)', entry)
    require(partition is not None and loader is not None,
            'efibootmgr device path is incomplete or not GPT')
    # File must follow HD directly, with no ignored intervening path nodes or
    # truncated suffix. Hardware nodes preceding HD are not identity fields.
    require(entry[partition.end():loader.start()] == '/' and
            not entry[loader.end():].strip(), 'unsupported efibootmgr path suffix')
    guid = str(uuid.UUID(partition[2]))
    require(guid != str(uuid.UUID(int=0)), 'empty EFI partition GUID')
    path = loader[1]
    require(path.startswith('\\EFI\\') and '..' not in path.split('\\') and '\0' not in path,
            'invalid efibootmgr loader path')
    return {'bootNumber': number, 'espPartitionGuid': guid, 'loaderPath': path}


def boot_current(efivars, run=command):
    # SecureBoot always comes from the actual EFI variable, including when
    # efibootmgr supplies the current boot's device path.
    secure = read(efivars / ('SecureBoot-' + EFI_GUID), 5)
    require(len(secure) == 5 and secure[4] in (0, 1), 'invalid SecureBoot variable')
    try:
        current = read(efivars / ('BootCurrent-' + EFI_GUID), 6)
        require(len(current) == 6, 'invalid BootCurrent length')
        number = struct.unpack_from('<H', current, 4)[0]
        option = read(efivars / ('Boot%04X-' % number + EFI_GUID))
    except OSError:
        result = decode_efibootmgr(run('efibootmgr', '-v'))
    else:
        result = decode_boot_option(option)
        result['bootNumber'] = '%04X' % number
    return result, secure[4] == 1


def normalize_image(value):
    return value.removeprefix('docker://')


def mount_rows(proc):
    def unescape(value):
        return re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), value)
    rows = []
    for line in read(proc / 'self/mountinfo').decode().splitlines():
        fields = line.split()
        split = fields.index('-')
        require(split >= 6 and len(fields) >= split + 4, 'invalid mountinfo')
        rows.append({'device': fields[2], 'root': unescape(fields[3]),
                     'target': unescape(fields[4]), 'type': fields[split + 1],
                     'source': unescape(fields[split + 2])})
    return rows


def collect(host, proc=Path('/proc'), sysroot=Path('/sys'), etc=Path('/etc'), run=command):
    plan = json.loads(read(host / 'wootc/install/installation.json'))
    require(plan.get('schemaVersion') == 1 and
            re.fullmatch('[0-9a-f]{32}', plan.get('installationId', '')),
            'missing installation identity')
    armed = datetime.datetime.fromisoformat(plan['armedAt'].replace('Z', '+00:00'))
    require(armed.tzinfo is not None, 'armedAt must include timezone')
    now = datetime.datetime.now(datetime.timezone.utc)
    require(armed <= now, 'installation is armed in the future')
    uptime = float(read(proc / 'uptime').decode().split()[0])
    require(uptime >= 0 and now - datetime.timedelta(seconds=uptime) >= armed,
            'current Linux boot predates this installation attempt')
    boot, secure = boot_current(sysroot / 'firmware/efi/efivars', run)
    require(boot['espPartitionGuid'].lower() == plan['espPartitionGuid'].lower() and
            boot['loaderPath'].lower() == plan['loaderPath'].lower(),
            'BootCurrent does not match staged ESP and loader')
    tokens = read(proc / 'cmdline').decode().split()
    def karg(name):
        values = [t.split('=', 1)[1] for t in tokens if t.startswith(name + '=')]
        require(len(values) == 1, 'missing or duplicate kernel argument ' + name)
        return values[0]
    disk_path, host_uuid = karg('loop'), karg('wootc.host_uuid').upper()
    require(disk_path == '/wootc/disks/root.disk' == plan['rootDiskPath'],
            'root.disk kernel argument does not match installation')
    require(re.fullmatch('[0-9A-F]{16}', host_uuid) and host_uuid == plan['hostUuid'].upper(),
            'host UUID kernel argument does not match installation')
    mounts = mount_rows(proc)
    private = [row for row in mounts if row['target'] == str(host)]
    require(len(private) == 1 and private[0]['type'] in ('ntfs3', 'fuseblk', 'ntfs'),
            'private host is not one NTFS mount')
    observed_uuid = run('blkid', '-s', 'UUID', '-o', 'value', private[0]['source']).strip().upper()
    require(observed_uuid == host_uuid, 'mounted NTFS UUID does not match installation')
    roots = [row for row in mounts if row['target'] == '/sysroot']
    require(len(roots) == 1, 'missing installed sysroot mount')
    def loop_backings(device, seen=None):
        seen = set() if seen is None else seen
        device = device.resolve(strict=True)
        require(device not in seen, 'cyclic root block-device ancestry')
        seen.add(device)
        if (device / 'partition').is_file():
            device = device.parent
        if (device / 'loop/backing_file').is_file():
            return [read(device / 'loop/backing_file').decode().strip()]
        slaves = list((device / 'slaves').iterdir()) if (device / 'slaves').is_dir() else []
        require(slaves, 'sysroot has no loop block-device ancestor')
        return [backing for slave in slaves for backing in loop_backings(slave, seen)]
    backings = loop_backings(sysroot / 'dev/block' / roots[0]['device'])
    require(backings == [str(host) + disk_path], 'installed sysroot is not this root.disk')
    require((host / disk_path.lstrip('/')).is_file(), 'installed root.disk is absent')
    config = dict(line.split('=', 1) for line in read(etc / 'wootc/host-esp.conf').decode().splitlines()
                  if line and not line.startswith('#'))
    source_image = config.get('SOURCE_IMAGE_REF', '')
    require(source_image and normalize_image(source_image) == normalize_image(plan['imageRef']),
            'installed source image does not match installation')
    status = json.loads(run('bootc', 'status', '--json'))
    booted = status['status']['booted']
    image = booted['image']['image']['image']
    digest = booted['image']['imageDigest']
    require(isinstance(image, str) and image and
            re.fullmatch('sha256:[0-9a-f]{64}', digest), 'missing booted image identity')
    installed_image = read(etc / 'wootc/installed-image-ref').decode().strip()
    require(normalize_image(image) == normalize_image(installed_image),
            'booted image does not match installed image')
    if '@sha256:' in installed_image:
        require(installed_image.rsplit('@', 1)[1] == digest, 'booted image digest differs from pinned install')
    for unit in ('wootc-host-bind.service', 'wootc-passthrough.service'):
        unit_state = dict(line.split('=', 1) for line in run('systemctl', 'show', unit,
                          '--property=ActiveState', '--property=SubState', '--property=Result').splitlines())
        require(unit_state == {'ActiveState': 'active', 'SubState': 'exited', 'Result': 'success'},
                'required bridge unit did not complete: ' + unit)
    # Enumerate real bind mounts, not the bridge journal's success message.
    accounts = []
    for line in read(etc / 'passwd').decode().splitlines():
        fields = line.split(':')
        if len(fields) == 7 and 1000 <= int(fields[2]) < 65534:
            accounts.append((fields[0], os.path.realpath(fields[5])))
    profile_map = {}
    map_path = etc / 'wootc/profile-map.tsv'
    if map_path.exists():
        for line in read(map_path).decode().splitlines():
            profile, account = line.split('\t')
            profile_map[profile] = account
    profile_roots = [private[0]]
    bitlocker = False
    for row in mounts:
        if row['target'] == '/run/wootc/bitlk-tmp':
            require(row['source'].startswith('/dev/mapper/wootc-bitlk-'),
                    'unexpected BitLocker profile source')
            unlocked = run('cryptsetup', 'status', row['source']).lower()
            require(re.search(r'type:\s*bitlk\b', unlocked), 'profile source is not unlocked BitLocker')
            profile_roots.append(row)
            bitlocker = True
    bindings, matched, matched_profiles = [], set(), []
    profiles = []
    for profile_root in profile_roots:
        profiles_path = Path(profile_root['target']) / 'Users'
        if profiles_path.is_dir():
            profiles.extend(p for p in profiles_path.iterdir() if p.is_dir() and
                            p.name not in ('Public', 'Default', 'Default User', 'All Users'))
    for profile in profiles:
        account = profile_map.get(profile.name, profile.name)
        if account in dict(accounts):
            matched.add(account)
            matched_profiles.append({'windowsProfile': profile.name, 'linuxUser': account,
                                     'profileRoot': str(profile)})
    # Match the bridge's single-user fallback across ALL discovered volumes.
    if not matched and len(profiles) == len(accounts) == 1:
        profile, account = profiles[0], accounts[0][0]
        matched.add(account)
        matched_profiles.append({'windowsProfile': profile.name, 'linuxUser': account,
                                 'profileRoot': str(profile)})
    for profile_root in profile_roots:
        for row in mounts:
            for account, home in accounts:
                if row['target'].startswith(home + '/') and row['target'][len(home) + 1:] in FOLDERS:
                    if row['device'] == profile_root['device']:
                        require(row['root'] != '/', 'bridge exposes the whole Windows volume')
                        source = profile_root['target'] + row['root']
                        require('wootc' not in [part.lower() for part in row['root'].split('/')],
                                'bridge exposes installer metadata')
                        bindings.append({'source': source, 'target': row['target'], 'user': account})
    require({binding['user'] for binding in bindings} <= matched,
            'bound folders lack an observed matching Windows profile')
    failed = run('systemctl', '--failed', '--no-legend', '--plain', '--no-pager').splitlines()
    failed_units = [line.split()[0] for line in failed if line.strip()]
    require(not failed_units, 'failed units prevent healthy: ' + ', '.join(failed_units))
    result = {'schemaVersion': 1, 'installationId': plan['installationId'], 'state': 'healthy',
            'kernel': os.uname().release, 'image': image, 'imageDigest': digest,
            'sourceImageRef': source_image, 'bootCurrent': boot,
            'rootDisk': {'path': disk_path, 'hostUuid': observed_uuid},
            'bridge': {'boundFolders': len(bindings), 'matchedUsers': len(matched),
                       'bitlockerUnlocked': bitlocker, 'bindings': bindings, 'matchedProfiles': matched_profiles},
            'secureBoot': secure, 'failedUnits': failed_units,
            'writtenAt': now.isoformat(timespec='seconds').replace('+00:00', 'Z'),
            'updatedBy': 'wootc-firstboot'}
    require(len(json.dumps(result, indent=2).encode()) <= 65536, 'boot evidence exceeds 64 KiB')
    return result


def publish_summary(evidence, directory):
    record = json.loads(read(evidence, 65536))
    summary = {name: record[name] for name in ('kernel', 'sourceImageRef', 'imageDigest', 'writtenAt')}
    summary.update({name: record['bridge'][name] for name in ('boundFolders', 'matchedUsers')})
    require(not directory.is_symlink(), 'summary directory cannot be a symlink')
    directory.mkdir(parents=True, exist_ok=True, mode=0o755)
    info = directory.stat()
    require(info.st_uid == os.geteuid() and not info.st_mode & 0o022,
            'summary directory must be owned by the service and not writable by other users')
    directory.chmod(0o755)
    target = directory / 'installed-linux-boot-summary.json'
    fd, temporary = tempfile.mkstemp(dir=directory, prefix='.firstboot-summary-')
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), 0o644)
            json.dump(summary, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
        directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', type=Path)
    parser.add_argument('--publish-summary', type=Path)
    parser.add_argument('--summary-dir', type=Path, default=Path('/var/lib/wootc'))
    args = parser.parse_args()
    try:
        if args.publish_summary:
            publish_summary(args.publish_summary, args.summary_dir)
        else:
            require(args.host is not None, '--host is required for collection')
            print(json.dumps(collect(args.host), indent=2))
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        print('first-boot evidence refused: ' + str(error), file=sys.stderr)
        sys.exit(1)
