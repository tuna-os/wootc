#!/usr/bin/env python3
"""Draft fixed read-only probe; not installed or connected by the current builder."""
import base64
import json
import io
import hashlib
import inspect
import stat
import importlib.util
import select
import selectors
import signal
import sys
import os
from pathlib import Path
import re
import subprocess
import time

MAX_MESSAGE = 256 * 1024
UUID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}')
IDENTITY_FIELDS = {'schemaVersion', 'runId', 'installId', 'diskId', 'sessionId', 'requestId', 'username', 'action', 'serviceSha256', 'ancestrySha256'}


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate probe field')
        result[key] = value
    return result


def request(raw):
    if len(raw) > MAX_MESSAGE:
        raise ValueError('probe request exceeds bound')
    depth = 0
    quoted = escaped = False
    for char in raw.decode('utf-8', errors='strict'):
        if quoted:
            if escaped: escaped = False
            elif char == '\\': escaped = True
            elif char == '"': quoted = False
        elif char == '"': quoted = True
        elif char in '{[':
            depth += 1
            if depth > 32: raise ValueError('probe nesting exceeds bound')
        elif char in '}]': depth -= 1
    def constant(value):
        raise ValueError('nonfinite JSON value')
    value = json.loads(raw, object_pairs_hook=unique, parse_constant=constant)
    if type(value) is not dict or set(value) != IDENTITY_FIELDS:
        raise ValueError('unknown or missing probe field')
    if type(value['schemaVersion']) is not int or value['schemaVersion'] != 1:
        raise ValueError('unknown probe schema')
    for field in ('runId', 'installId'):
        if type(value[field]) is not str or not re.fullmatch(r'[A-Za-z0-9._-]{1,128}', value[field]):
            raise ValueError('invalid probe identity')
    for field in ('sessionId', 'requestId'):
        if type(value[field]) is not str or not re.fullmatch(r'[0-9a-f]{32}', value[field]):
            raise ValueError('invalid probe nonce')
    if type(value['diskId']) is not str or not UUID.fullmatch(value['diskId']):
        raise ValueError('invalid disk identity')
    if type(value['username']) is not str or not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', value['username']):
        raise ValueError('invalid ordinary username')
    for field in ('serviceSha256', 'ancestrySha256'):
        if type(value[field]) is not str or not re.fullmatch(r'[0-9a-f]{64}', value[field]):
            raise ValueError('invalid authenticated source hash')
    if value['action'] != 'observe-boot-session':
        raise ValueError('unsupported read-only probe action')
    return value


def _run_owned(argv, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError('probe deadline expired')
    # All argv are fixed by this module; no request accepts executable/argv/path.
    child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             start_new_session=True)
    until = min(deadline, time.monotonic() + 2)
    collected = {child.stdout: bytearray(), child.stderr: bytearray()}
    selector = selectors.DefaultSelector()
    try:
        for stream in collected:
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ)
        while selector.get_map():
            remaining = until - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('read-only child observation deadline expired')
            for key, _ in selector.select(remaining):
                chunk = os.read(key.fd, 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                collected[key.fileobj].extend(chunk)
                if len(collected[key.fileobj]) > MAX_MESSAGE:
                    raise ValueError('read-only child output exceeds bound')
        # Observe exit without reaping, preserving owned PID/group identity
        # until cancellation and cleanup complete. This service is Linux-only.
        info = None
        while info is None:
            if time.monotonic() >= until:
                raise TimeoutError('read-only child exit deadline expired')
            info = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOWAIT | os.WNOHANG)
            if info is None: time.sleep(min(0.01, max(0, until-time.monotonic())))
        if info.si_code != os.CLD_EXITED or info.si_status != 0:
            raise ValueError('read-only observation failed: ' + argv[0])
        return collected[child.stdout].decode('utf-8', errors='strict').strip()
    finally:
        selector.close()
        try:
            # Only the process group freshly owned by this fixed command.
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait(timeout=0.5)
        child.stdout.close()
        child.stderr.close()


TOOLS = {'loginctl': '/usr/bin/loginctl', 'lsblk': '/usr/bin/lsblk',
         'findmnt': '/usr/bin/findmnt', 'losetup': '/usr/sbin/losetup'}


def protected_file(path):
    path = Path(path)
    resolved = path.resolve(strict=True)
    for entry in [resolved, *resolved.parents]:
        observed = entry.stat()
        if observed.st_uid != 0 or observed.st_mode & 0o022:
            raise ValueError('unprotected guest observation dependency')
    if not stat.S_ISREG(resolved.stat().st_mode):
        raise ValueError('guest observation dependency is not a regular file')
    return resolved


def run(argv, deadline):
    if not argv or argv[0] not in TOOLS:
        raise ValueError('unsupported guest observation executable')
    resolved = protected_file(TOOLS[argv[0]])
    if not os.access(resolved, os.X_OK):
        raise ValueError('fixed observation executable unavailable')
    return _run_owned([str(resolved), *argv[1:]], deadline)


def boot():
    value = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    if not UUID.fullmatch(value):
        raise ValueError('invalid current kernel boot identity')
    return value


def properties(raw):
    result = {}
    for line in raw.splitlines():
        key, sep, value = line.partition('=')
        if not sep or key in result:
            raise ValueError('ambiguous session properties')
        result[key] = value
    expected = {'Id', 'User', 'Name', 'Active', 'Remote', 'Type', 'Class', 'State', 'Leader'}
    if set(result) != expected:
        raise ValueError('missing session property')
    return result


def ordinary_session(username, deadline):
    ids = run(['loginctl', 'list-sessions', '--no-legend', '--no-pager'], deadline)
    candidates = []
    lines = ids.splitlines()
    if len(lines) > 64:
        raise ValueError('session inventory exceeds bound')
    for line in lines:
        fields = line.split()
        if not fields or not re.fullmatch(r'[A-Za-z0-9_-]{1,32}', fields[0]):
            raise ValueError('invalid session identity')
        raw = run(['loginctl', 'show-session', fields[0], '--no-pager',
                   '--property=Id,User,Name,Active,Remote,Type,Class,State,Leader'], deadline)
        row = properties(raw)
        if row['Name'] != username or row['Active'] != 'yes' or row['Remote'] != 'no':
            continue
        if row['Class'] != 'user' or row['State'] != 'active' or row['Type'] not in {'wayland', 'x11'}:
            continue
        if not re.fullmatch(r'[1-9][0-9]{0,9}', row['User']) or not re.fullmatch(r'[1-9][0-9]{0,9}', row['Leader']):
            raise ValueError('invalid session process or uid')
        if int(row['User']) < 1000 or row['Id'] != fields[0]:
            raise ValueError('session is not an ordinary user')
        import pwd
        if pwd.getpwnam(username).pw_uid != int(row['User']):
            raise ValueError('session does not match selected account uid')
        leader = Path('/proc') / row['Leader']
        status = (leader / 'status').read_text()
        uid_lines = [line for line in status.splitlines() if line.startswith('Uid:')]
        if len(uid_lines) != 1 or uid_lines[0].split()[1:] != [row['User']] * 4:
            raise ValueError('graphical session leader uid mismatch')
        process_stat = (leader / 'stat').read_text()
        head, separator, tail = process_stat.rpartition(')')
        fields = tail.split()
        if not separator or not head.startswith(row['Leader'] + ' (') or len(fields) < 20 or not fields[19].isdigit():
            raise ValueError('session leader start identity unavailable')
        row['LeaderStartTicks'] = fields[19]
        candidates.append(row)
    if len(candidates) != 1:
        raise ValueError('unique active ordinary graphical session not observed')
    return candidates[0]


def encoded(value):
    return base64.b64encode(value.encode()).decode()


def backing(disk_id, deadline, ancestry_type):
    raw_blocks = run(['lsblk', '--json', '--paths', '--output', 'NAME,KNAME,TYPE,MAJ:MIN,PKNAME,UUID,PTUUID'], deadline)
    blocks = json.loads(raw_blocks, object_pairs_hook=unique)
    targets = []
    def visit(rows, depth=0):
        if type(rows) is not list or depth > 32:
            raise ValueError('invalid block inventory')
        for row in rows:
            if row.get('type') == 'disk' and row.get('ptuuid') == disk_id:
                targets.append(row['name'])
            if 'children' in row:
                visit(row['children'], depth+1)
    visit(blocks['blockdevices'])
    if len(targets) != 1:
        raise ValueError('unique selected GPT target not measured')
    mounts = run(['findmnt', '--json', '--output', 'TARGET,SOURCE,FSTYPE,MAJ:MIN,OPTIONS,UUID'], deadline)
    loops = run(['losetup', '--json', '--output', 'NAME,MAJ:MIN,BACK-FILE'], deadline)
    root_options = run(['findmnt', '--noheadings', '--raw', '--output', 'OPTIONS', '--target', '/'], deadline)
    loop_files = run(['losetup', '--noheadings', '--raw', '--output', 'BACK-FILE'], deadline)
    paths = set(loop_files.splitlines())
    for option in root_options.split(','):
        key, sep, value = option.partition('=')
        if sep and key.rstrip('+') in {'lowerdir', 'datadir', 'upperdir', 'workdir'}:
            paths.update(value.split(':'))
    paths.discard('')
    if len(paths) > 512:
        raise ValueError('projection inventory exceeds bound')
    resolved = []
    for path in sorted(paths):
        if not path.startswith('/') or any(c.isspace() for c in path) or '\\' in path:
            raise ValueError('ambiguous projection path')
        try:
            canonical = str(Path(path).resolve(strict=True))
        except OSError:
            canonical = '-'
        resolved.append(path + '\t' + canonical)
    btrfs = []
    roots = list(Path('/sys/fs/btrfs').glob('*'))
    if len(roots) > 128:
        raise ValueError('Btrfs inventory exceeds bound')
    for fs in roots:
        if not (fs / 'devinfo').is_dir():
            continue
        infos = list((fs / 'devinfo').glob('*'))
        devices = list((fs / 'devices').glob('*'))
        if len(infos) > 1024 or len(devices) > 1024:
            raise ValueError('Btrfs member inventory exceeds bound')
        valid = bool(devices) and len(infos) == len(devices)
        for info in infos:
            facts = [(info / field).read_text().strip() for field in ('missing', 'in_fs_metadata', 'replace_target')]
            valid = valid and facts == ['0', '1', '0']
        majors = [(device / 'dev').read_text().strip() for device in devices]
        btrfs.append(fs.name + '\t' + ('1' if valid else '0') + '\t' + ','.join(majors))
    measured = {'BLOCKS': encoded(raw_blocks), 'MOUNTS': encoded(mounts), 'LOOPS': encoded(loops),
                'PATHS': encoded('\n'.join(resolved)), 'BTRFS': encoded('\n'.join(btrfs))}
    graph = ancestry_type(measured, targets[0])
    graph.verify_root()
    return {'target': targets[0], 'diskId': disk_id, 'currentRootVerified': True, 'measurements': measured}


def observe(value, ancestry_type):
    deadline = time.monotonic() + 8
    actual_service = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    actual_ancestry = hashlib.sha256(Path(inspect.getsourcefile(ancestry_type)).read_bytes()).hexdigest()
    if (actual_service, actual_ancestry) != (value['serviceSha256'], value['ancestrySha256']):
        raise ValueError('guest observation source differs from authenticated request')
    before = boot()
    if os.uname().sysname != 'Linux':
        raise ValueError('current Linux identity not observed')
    kernel = os.uname().release
    first = ordinary_session(value['username'], deadline)
    root = backing(value['diskId'], deadline, ancestry_type)
    second = ordinary_session(value['username'], deadline)
    if first != second or before != boot() or time.monotonic() >= deadline:
        raise ValueError('boot or ordinary session changed during observation')
    return dict(value, status='observed', bootId=before, kernelRelease=kernel,
                ordinarySession=first, root=root, desktopQualified=False,
                editorQualified=False)


def read_frame(stream):
    if isinstance(stream, io.BytesIO):
        return stream.readline(MAX_MESSAGE + 1)
    fd = stream.fileno()
    deadline = time.monotonic() + 30
    frame = bytearray()
    while len(frame) <= MAX_MESSAGE:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise TimeoutError('probe framing deadline expired')
        part = os.read(fd, 1)
        if not part:
            return bytes(frame)
        if not frame:
            deadline = time.monotonic() + 3
        frame.extend(part)
        if part == b'\n':
            return bytes(frame)
    return bytes(frame)


def write_reply(output, reply):
    if isinstance(output, io.BytesIO):
        output.write(reply)
        return
    fd = output.fileno()
    blocking = os.get_blocking(fd)
    os.set_blocking(fd, False)
    deadline = time.monotonic() + 2
    offset = 0
    try:
        while offset < len(reply):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([], [fd], [], remaining)[1]:
                raise TimeoutError('probe reply deadline expired')
            try:
                written = os.write(fd, reply[offset:offset+4096])
            except BlockingIOError:
                continue
            if written <= 0:
                raise ValueError('probe reply write failed')
            offset += written
    finally:
        os.set_blocking(fd, blocking)


def serve(stream, output, ancestry_type):
    seen = set()
    identity = None
    for _ in range(128):
        raw = read_frame(stream)
        if not raw:
            return
        if len(raw) > MAX_MESSAGE or not raw.endswith(b'\n'):
            raise ValueError('invalid framed probe request')
        value = request(raw)
        current = {key: value[key] for key in IDENTITY_FIELDS - {'requestId'}}
        if identity is not None and identity != current:
            raise ValueError('probe channel identity changed')
        identity = current
        if value['requestId'] in seen:
            raise ValueError('replayed probe request')
        seen.add(value['requestId'])
        receipt = observe(value, ancestry_type)
        reply = json.dumps(receipt, separators=(',', ':')).encode() + b'\n'
        if len(reply) > MAX_MESSAGE:
            raise ValueError('probe reply exceeds bound')
        write_reply(output, reply)
    raise ValueError('probe session request budget exhausted')


def main():
    # Future authenticated personalization must stage the reviewed ancestry
    # module alongside this file. This draft changes no installed image.
    namespace = Path('/var/usrlocal/lib/wootc/observer')
    service = protected_file(namespace / 'boot_probe.py')
    if service != Path(__file__).resolve(strict=True):
        raise ValueError('guest observer launched from another namespace')
    dependency = protected_file(namespace / 'wootc_ancestry.py')
    # Explicit protected file loading; no user cwd/PYTHONPATH import search.
    spec = importlib.util.spec_from_file_location('wootc_ancestry', dependency)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    Ancestry = module.Ancestry
    path = Path('/dev/virtio-ports/org.wootc.observation.1')
    resolved = path.resolve(strict=True)
    if not str(resolved).startswith('/dev/vport') or not stat.S_ISCHR(resolved.stat().st_mode):
        raise ValueError('dedicated virtio observation character device unavailable')
    with resolved.open('r+b', buffering=0) as channel:
        serve(channel, channel, Ancestry)


if __name__ == '__main__':
    main()
