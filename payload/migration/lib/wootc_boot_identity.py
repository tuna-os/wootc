"""Fresh EFI/root observations reused from the verified firstboot collector.

Source:63a0d7ce654addf821ccfd0f99e4678ccbac5972 collector file SHA256
 afbb6575595decec72762546eb7209d21a618b9144358e4f9966efb201950da7.
This module reads the current boot. It never reads a cached success record.
"""
from pathlib import Path
import json
import re
import struct
import subprocess
import uuid
EFI_GUID = '8be4df61-93ca-11d2-aa0d-00e098032b8c'

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


def observe_installed_boot(esp, host, expected_esp_uuid, proc=Path('/proc'),
                           sysroot=Path('/sys'), run=command):
    esp, host = Path(esp), Path(host)
    tokens = read(proc / 'cmdline').decode().split()
    def argument(name):
        values = [value.split('=', 1)[1] for value in tokens if value.startswith(name + '=')]
        require(len(values) == 1, 'missing/duplicate loop boot argument: ' + name)
        return values[0]
    # Native graduation currently retains old host-esp.conf (#286). Positively
    # require this mounted root's loop ancestry before touching the Windows ESP.
    require(any(value.startswith('loop=') for value in tokens),
            'native/unknown root cannot refresh the previous Windows ESP')
    disk_path = argument('loop')
    host_uuid = argument('wootc.host_uuid').upper()
    require(disk_path == '/wootc/disks/root.disk' and re.fullmatch('[0-9A-F]{16}', host_uuid),
            'unsupported root.disk identity')
    mounts = mount_rows(proc)
    private = [row for row in mounts if row['target'] == str(host)]
    require(len(private) == 1 and private[0]['type'] in ('ntfs3', 'fuseblk', 'ntfs'),
            'private host is not one NTFS mount')
    observed_host = run('blkid', '-s', 'UUID', '-o', 'value', private[0]['source']).strip().upper()
    require(observed_host == host_uuid, 'mounted NTFS UUID differs from cmdline')
    try:
        status = json.loads(run('bootc', 'status', '--json'))
    except FileNotFoundError:
        status = None
    except (subprocess.SubprocessError, json.JSONDecodeError) as error:
        raise ValueError('cannot measure installed bootc deployment') from error
    root_target = '/sysroot' if status is not None else '/'
    roots = [row for row in mounts if row['target'] == root_target]
    require(len(roots) == 1, 'missing installed root mount')
    backings = loop_backings(sysroot / 'dev/block' / roots[0]['device'])
    require(backings == [str(host) + disk_path], 'installed root is not this root.disk')
    require((host / disk_path.lstrip('/')).is_file(), 'actual root.disk absent')
    mounted_esp = [row for row in mounts if row['target'] == str(esp)]
    require(len(mounted_esp) == 1 and mounted_esp[0]['type'] in ('vfat', 'msdos'),
            'refresh destination is not one FAT ESP mount')
    device = mounted_esp[0]['source']
    observed_esp_uuid = run('blkid', '-s', 'UUID', '-o', 'value', device).strip()
    require(observed_esp_uuid.upper() == expected_esp_uuid.upper(), 'mounted ESP UUID differs from config')
    partition_guid = run('blkid', '-s', 'PARTUUID', '-o', 'value', device).strip().lower()
    require(str(uuid.UUID(partition_guid)) == partition_guid, 'invalid mounted ESP GPT identity')
    boot, secure = boot_current(sysroot / 'firmware/efi/efivars', run)
    require(boot['espPartitionGuid'].lower() == partition_guid, 'BootCurrent is on a different ESP')
    match = re.fullmatch(r'\\EFI\\([^\\]+)\\shimx64\.efi', boot['loaderPath'], flags=re.IGNORECASE)
    require(match and match[1] not in ('.', '..'), 'current EFI boot is not a vendor shim')
    boot_id = read(proc / 'sys/kernel/random/boot_id').decode().strip()
    require(str(uuid.UUID(boot_id)) == boot_id, 'invalid actual kernel boot ID')
    observed = {'bootId': boot_id, 'bootCurrent': boot, 'secureBoot': secure,
                'hostEspUuid': observed_esp_uuid, 'loaderVendor': match[1],
                'rootKind': 'loop', 'rootDiskPath': disk_path, 'hostUuid': observed_host}
    if status is None:
        root_uuid = run('blkid', '-s', 'UUID', '-o', 'value', roots[0]['source']).strip()
        require(root_uuid and roots[0]['type'] not in ('overlay', 'tmpfs'),
                'missing classic root filesystem identity')
        observed.update(deploymentKind='classic', rootDevice=roots[0]['device'],
                        rootFsUuid=root_uuid, rootFsType=roots[0]['type'])
        return observed
    booted = status['status']['booted']
    image = booted['image']['image']['image']
    image_digest = booted['image']['imageDigest']
    require(isinstance(image, str) and image and
            re.fullmatch('sha256:[0-9a-f]{64}', image_digest), 'missing actual booted deployment identity')
    observed.update(deploymentKind='bootc', imageRef=image, imageDigest=image_digest)
    return observed
