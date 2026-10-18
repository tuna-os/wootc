"""Prepare and start one private scratch VM; default mode only checks inputs."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import stat
import struct
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
GLOBAL = '8be4df61-93ca-11d2-aa0d-00e098032b8c'
DB_GUID = 'd719b2cb-3d3a-4596-a3bc-dad00e67656f'
NV_GUID = uuid.UUID('fff12b8d-7696-4c8b-a985-2747075b4f50').bytes_le
AUTH_GUID = uuid.UUID('aaf32c78-947b-439a-a180-2e144ec37792').bytes_le


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def variables(path):
    # Packed x86 layouts: EDK2 VariableFormat.h and PI PiFirmwareVolume.h.
    # https://github.com/tianocore/edk2/blob/master/MdeModulePkg/Include/Guid/VariableFormat.h
    # This accepts one raw authenticated OVMF NV volume; unknown layouts refuse.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or not 72 <= before.st_size <= 16*1024*1024:
            raise ValueError('unsupported variable-store file or size')
        stream = os.fdopen(descriptor, 'rb'); descriptor = -1
        with stream:
            raw = stream.read(16*1024*1024+1)
            after = os.fstat(stream.fileno())
        snapshot = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        if len(raw) != before.st_size or snapshot(before) != snapshot(after):
            raise ValueError('variable store changed while reading')
    finally:
        if descriptor != -1: os.close(descriptor)
    if not 72 <= len(raw) <= 16*1024*1024 or raw[16:32] != NV_GUID or raw[40:44] != b'_FVH':
        raise ValueError('unsupported raw OVMF NV volume')
    length = struct.unpack_from('<Q', raw, 32)[0]
    header = struct.unpack_from('<H', raw, 48)[0]
    if not 72 <= header <= length <= len(raw) or header % 2 or sum(struct.unpack('<'+'H'*(header//2), raw[:header])) & 65535:
        raise ValueError('truncated volume or bad header checksum')
    if raw[header:header+16] != AUTH_GUID or header+28 > length:
        raise ValueError('unsupported authenticated variable store')
    size, fmt, state = struct.unpack_from('<IBB', raw, header+16)
    end = header+size
    if fmt != 0x5a or state != 0xfe or size < 28 or end > length:
        raise ValueError('truncated or unhealthy variable store')
    result = {}; pos = header+28
    while pos < end:
        if raw[pos:pos+2] == b'\xff\xff':
            if any(b != 255 for b in raw[pos:end]):
                raise ValueError('non-erased variable tail')
            break
        if pos+60 > end:
            raise ValueError('truncated variable header')
        magic, state, attributes = struct.unpack_from('<HBxI', raw, pos)
        namesize, datasize = struct.unpack_from('<II', raw, pos+36)
        finish = pos+60+namesize+datasize
        if magic != 0x55aa or state not in (0x3f, 0x3e, 0x3c, 0x3d, 0x7f) or namesize < 2 or namesize % 2 or finish > end:
            raise ValueError('unknown state or truncated variable')
        namebytes = raw[pos+60:pos+60+namesize]
        if not namebytes.endswith(b'\0\0'):
            raise ValueError('unterminated variable name')
        name = namebytes[:-2].decode('utf-16le')
        if not name or '\0' in name:
            raise ValueError('invalid variable name')
        guid = str(uuid.UUID(bytes_le=raw[pos+44:pos+60]))
        if state == 0x3f:
            key = name+'-'+guid
            if key in result:
                raise ValueError('ambiguous active variable')
            result[key] = struct.pack('<I', attributes)+raw[pos+60+namesize:finish]
        pos = (finish+3) & ~3
    return result


def private_file(path, folder=None):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('file is not private and owned: '+str(path))
    if folder is not None and path.resolve().parent != folder:
        raise ValueError('file escapes scratch identity')
    return path


def freeze(source, target, expected):
    source, target = Path(source), Path(target)
    if source.is_symlink() or digest(source) != expected:
        raise ValueError('launch source differs from pin')
    with source.open('rb') as reader, target.open('xb') as writer:
        shutil.copyfileobj(reader, writer); writer.flush(); os.fsync(writer.fileno())
    target.chmod(0o400)
    if digest(source) != expected or digest(target) != expected:
        raise ValueError('launch source changed while freezing')


def trusted_qemu(path):
    path = Path(path).resolve(strict=True)
    info = path.stat()
    if path != Path('/usr/bin/qemu-system-x86_64') or info.st_uid != 0 or info.st_mode & 0o022:
        raise ValueError('QEMU must be the protected installed host executable')


def trusted_firmware(entry):
    # Source checkpoint: Ubuntu ovmf 2024.02-2ubuntu0.9, actual secboot code.
    # Package README.Debian describes this build as aborting without SMM.
    # Other firmware builds need their own reviewed source-to-byte contract.
    if entry['sha256'] != '1dbb7f9b7e7285b950929bbbc1494c186bfb061cde60cf531ff9756ef87dab7a':
        raise ValueError('firmware code has no reviewed SMM-required source contract')


def checked(folder, record, config, executable_policy=trusted_qemu, firmware_policy=trusted_firmware):
    folder = Path(folder)
    if folder.is_symlink(): raise ValueError('scratch directory symlink')
    folder = folder.resolve(strict=True)
    if any(c in str(folder) for c in (',', '\n', '\0')):
        raise ValueError('unsupported scratch option path')
    info = folder.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('scratch directory is not private and owned')
    if str(uuid.UUID(record['vmUuid'])) != record['vmUuid'] or uuid.UUID(record['vmUuid']).hex != record['scratchId'] or folder.name != record['scratchId']:
        raise ValueError('scratch UUID/directory differs')
    private_file(record['overlay'], folder)
    if record['state'] != 'classic-offline-baseline-produced':
        raise ValueError('scratch baseline is not ready for its first launch')
    plan_path = private_file(folder/'plan.json', folder)
    if digest(plan_path) != record['planSha256']:
        raise ValueError('producer plan changed')
    plan = json.loads(plan_path.read_text())
    if plan['scratchId'] != record['scratchId'] or plan['vmUuid'] != record['vmUuid']:
        raise ValueError('producer plan belongs to another scratch')
    for key in ('qemu', 'firmwareCode', 'firmwareStore'):
        entry = config[key]; path = Path(entry['path'])
        if key in ('firmwareCode', 'firmwareStore') and not 72 <= path.lstat().st_size <= 16*1024*1024:
            raise ValueError('firmware file size is outside the bound')
        if path.is_symlink() or not path.is_file() or not re.fullmatch('[0-9a-f]{64}', entry['sha256']) or digest(path) != entry['sha256']:
            raise ValueError('launch input differs: '+key)
        if any(c in str(path) for c in (',', '\n', '\0')):
            raise ValueError('unsupported QEMU option path')
    qemu = Path(config['qemu']['path'])
    if qemu.name != 'qemu-system-x86_64' or not os.access(qemu, os.X_OK):
        raise ValueError('not a pinned QEMU executable')
    executable_policy(qemu)
    firmware_policy(config['firmwareCode'])
    if type(config['memoryMiB']) is not int or type(config['cpus']) is not int:
        raise ValueError('VM resources must be integers')
    if not 2048 <= config['memoryMiB'] <= 32768 or not 1 <= config['cpus'] <= 16:
        raise ValueError('unbounded VM resources')
    # New TPM state cannot unlock a retained TPM-bound volume. Initial scope is
    # explicitly an unencrypted QA baseline; a real Windows observation is owed.
    if config['tpmMode'] != 'none-unencrypted-qa':
        raise ValueError('TPM baseline cloning is not implemented')
    store = variables(config['firmwareStore']['path'])
    measured = {}
    for name in ('db', 'dbx'):
        raw = store[name+'-'+DB_GUID]
        actual = hashlib.sha256(raw).hexdigest()
        if actual != plan['firmwareTrustHashes'][name]:
            raise ValueError('NV store '+name+' differs from pinned guest export')
        measured[name] = actual
    # Runtime variables are not inferred from this disk file. First guest capture
    # must separately match all six pinned runtime hashes before any upgrade.
    return folder, plan, measured


def prepare(folder, record, config, executable_policy=trusted_qemu, firmware_policy=trusted_firmware):
    folder, plan, measured = checked(folder, record, config, executable_policy, firmware_policy)
    for name in ('launch.json', 'qemu.pid', 'qga.sock', 'firmware-code.fd', 'firmware-baseline.fd', 'firmware-active.fd'):
        if (folder/name).exists() or (folder/name).is_symlink():
            raise ValueError('launch identity already exists')
    freeze(config['firmwareCode']['path'], folder/'firmware-code.fd', config['firmwareCode']['sha256'])
    freeze(config['firmwareStore']['path'], folder/'firmware-baseline.fd', config['firmwareStore']['sha256'])
    freeze(folder/'firmware-baseline.fd', folder/'firmware-active.fd', config['firmwareStore']['sha256'])
    (folder/'firmware-active.fd').chmod(0o600)
    qemu = Path(config['qemu']['path']).resolve(strict=True)
    argv = [str(qemu), '-machine', 'q35,smm=on', '-accel', 'kvm', '-cpu', 'host',
            '-global', 'driver=cfi.pflash01,property=secure,value=on',
            '-global', 'ICH9-LPC.disable_s3=1', '-m', str(config['memoryMiB']), '-smp', str(config['cpus']), '-uuid', record['vmUuid'],
            '-drive', 'if=pflash,format=raw,unit=0,readonly=on,file='+str(folder/'firmware-code.fd'),
            '-drive', 'if=pflash,format=raw,unit=1,file='+str(folder/'firmware-active.fd'),
            '-drive', 'if=none,id=system,format=qcow2,file='+record['overlay'], '-device', 'ide-hd,drive=system',
            '-device', 'virtio-serial-pci', '-chardev', 'socket,id=qga,path='+str(folder/'qga.sock')+',server=on,wait=off',
            '-device', 'virtserialport,chardev=qga,name=org.qemu.guest_agent.0',
            '-netdev', 'user,id=net', '-device', 'e1000,netdev=net', '-display', 'none', '-monitor', 'none',
            '-serial', 'file:'+str(folder/'serial.log')]
    launch = {'schemaVersion': 1, 'scratchId': record['scratchId'], 'vmUuid': record['vmUuid'],
              'firmwareSourceVerified': firmware_policy is trusted_firmware, 'executableTrustVerified': executable_policy is trusted_qemu, 'argv': argv, 'qemuSha256': config['qemu']['sha256'], 'qemuPath': str(qemu),
              'firmwareCodeSha256': config['firmwareCode']['sha256'],
              'firmwareBaselineSha256': config['firmwareStore']['sha256'], 'measuredNvHashes': measured,
              'planSha256': record['planSha256'], 'overlay': record['overlay'],
              'tpmMode': config['tpmMode'], 'state': 'prepared', 'firmwareStoreBindingVerified': False}
    with (folder/'launch.json').open('x') as stream:
        json.dump(launch, stream, sort_keys=True); stream.flush(); os.fsync(stream.fileno())
    (folder/'launch.json').chmod(0o600)
    directory = os.open(folder, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(directory)
    finally: os.close(directory)
    return launch


def process_identity(pid):
    process = Path('/proc')/str(pid)
    # comm may contain spaces/parentheses; field22 starts after the final ')'.
    start = process.joinpath('stat').read_text().rsplit(')', 1)[1].split()[19]
    return {'pid': pid, 'startTicks': start, 'executableSha256': digest(process/'exe')}


def start(folder, record, launch):
    folder = Path(folder)
    # No old process is killed or socket removed; launch is once per identity.
    if (folder/'qemu.pid').exists() or (folder/'qga.sock').exists():
        raise ValueError('scratch process or socket already exists')
    trusted_qemu(launch['qemuPath'])
    trusted_firmware({'sha256': launch['firmwareCodeSha256']})
    if not launch['firmwareSourceVerified']:
        raise ValueError('launcher firmware source is a fixture')
    if not launch['executableTrustVerified']:
        raise ValueError('launcher executable trust is a fixture')
    if digest(launch['qemuPath']) != launch['qemuSha256'] or digest(folder/'firmware-code.fd') != launch['firmwareCodeSha256'] or digest(folder/'firmware-baseline.fd') != launch['firmwareBaselineSha256'] or digest(folder/'firmware-active.fd') != launch['firmwareBaselineSha256']:
        raise ValueError('prepared launcher input changed')
    if not os.access('/dev/kvm', os.R_OK | os.W_OK):
        raise ValueError('KVM is not accessible')
    child = None
    log = os.open(folder/'qemu.log', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        child = subprocess.Popen(launch['argv'], stdin=subprocess.DEVNULL, stdout=log, stderr=log, close_fds=True)
        identity = process_identity(child.pid)
        if identity['executableSha256'] != launch['qemuSha256']:
            raise ValueError('executed binary differs from pinned QEMU')
        launch.update(identity, state='running')
        with (folder/'qemu.pid').open('x') as stream: stream.write(str(child.pid))
        (folder/'qemu.pid').chmod(0o600)
        with (folder/'launch.json').open('w') as stream:
            json.dump(launch, stream, sort_keys=True); stream.flush(); os.fsync(stream.fileno())
        (folder/'launch.json').chmod(0o400)
        record.update(state='classic-scratch-running', launchSha256=digest(folder/'launch.json'))
        with (folder/'scratch.json').open('w') as stream:
            json.dump(record, stream, sort_keys=True); stream.flush(); os.fsync(stream.fileno())
        deadline = time.monotonic()+60
        while not (folder/'qga.sock').exists():
            if child.poll() is not None or time.monotonic() >= deadline:
                raise ValueError('QEMU did not publish its QGA socket before deadline')
            time.sleep(max(0, min(.1, deadline-time.monotonic())))
        runpy.run_path(str(Path(__file__).with_name('orchestrate.py')))['check_vm'](folder, record)
        return launch
    except BaseException:
        if child is not None and child.poll() is None:
            child.terminate()
            try: child.wait(timeout=2)
            except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=2)
        raise
    finally:
        os.close(log)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('scratch', type=Path); parser.add_argument('config', type=Path)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    try:
        private_file(args.scratch/'scratch.json')
        record = json.loads((args.scratch/'scratch.json').read_text()); config = json.loads(args.config.read_text())
        if not args.execute:
            checked(args.scratch, record, config)
            print(json.dumps({'inputsMatch': True, 'executed': False, 'firmwareStoreBindingVerified': False}))
        else:
            lock = os.open(args.scratch/'launch.lock', os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print(json.dumps(start(args.scratch, record, prepare(args.scratch, record, config)), sort_keys=True))
    except (OSError, ValueError, KeyError, struct.error, subprocess.SubprocessError) as error:
        parser.exit(1, 'launcher refused: '+str(error)+'\n')
