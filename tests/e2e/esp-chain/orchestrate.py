"""Execute fresh QGA captures in one exclusively owned scratch VM; no VM launcher."""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import runpy
import secrets
import stat
import socket
import time

ROOT = Path(__file__).resolve().parents[3]
GuestAgent = runpy.run_path(str(ROOT/'tests/e2e/qga.py'))['GuestAgent']
acceptance = runpy.run_path(str(Path(__file__).with_name('accept.py')))
validate, validate_firmware, validate_initial = (acceptance[n] for n in ('validate', 'validate_firmware', 'validate_initial'))


def check_vm(folder, record, executable_policy=None):
    folder = Path(folder)
    if folder.is_symlink(): raise ValueError('scratch VM directory symlink')
    folder = folder.resolve(strict=True)
    info = folder.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('scratch VM directory is not private and owned')
    overlay_info = Path(record['overlay']).lstat()
    if not stat.S_ISREG(overlay_info.st_mode) or overlay_info.st_uid != os.getuid() or overlay_info.st_mode & 0o077:
        raise ValueError('overlay is not private and owned')
    if Path(record['overlay']).is_symlink() or Path(record['overlay']).resolve(strict=True).parent != folder:
        raise ValueError('overlay escapes scratch identity')
    pid_file = folder/'qemu.pid'
    info = pid_file.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('QEMU pid file is not private and owned')
    pid = int(pid_file.read_text().strip())
    process = Path('/proc')/str(pid)
    if process.stat().st_uid != os.getuid():
        raise ValueError('QEMU process owner differs')
    args = process.joinpath('cmdline').read_bytes().decode().rstrip('\0').split('\0')
    if process.joinpath('exe').resolve(strict=True).name != 'qemu-system-x86_64' or args.count('-uuid') != 1:
        raise ValueError('not one owned QEMU process')
    launch_path = folder/'launch.json'
    info = launch_path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('launch record is not private and owned')
    if hashlib.sha256(launch_path.read_bytes()).hexdigest() != record['launchSha256']:
        raise ValueError('launch record differs from scratch pin')
    launch = json.loads(launch_path.read_text())
    if executable_policy is None:
        policies = runpy.run_path(str(Path(__file__).with_name('launch.py')))
        policies['trusted_qemu'](launch['qemuPath'])
        policies['trusted_firmware']({'sha256': launch['firmwareCodeSha256']})
        if not launch['firmwareSourceVerified']:
            raise ValueError('QEMU firmware source is a fixture')
        if not launch['executableTrustVerified']:
            raise ValueError('QEMU executable trust is a fixture')
    else:
        executable_policy(launch['qemuPath'])
    if launch['argv'] != args or launch['vmUuid'] != record['vmUuid'] or launch['scratchId'] != record['scratchId'] or launch['overlay'] != record['overlay'] or launch['planSha256'] != record['planSha256']:
        raise ValueError('actual QEMU arguments differ from frozen launch identity')
    if str(pid) != str(launch['pid']) or process.joinpath('stat').read_text().rsplit(')', 1)[1].split()[19] != launch['startTicks']:
        raise ValueError('QEMU PID was reused')
    with process.joinpath('exe').open('rb') as stream:
        executable_hash = hashlib.file_digest(stream, 'sha256').hexdigest()
    if executable_hash != launch['qemuSha256'] or launch['executableSha256'] != executable_hash:
        raise ValueError('actual QEMU executable differs')
    for name, key in [('firmware-code.fd', 'firmwareCodeSha256'), ('firmware-baseline.fd', 'firmwareBaselineSha256')]:
        path = folder/name; info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o277:
            raise ValueError('firmware source is not private and immutable')
        if hashlib.sha256(path.read_bytes()).hexdigest() != launch[key]:
            raise ValueError('immutable firmware source changed')
    handles = {os.readlink(p) for p in process.joinpath('fd').iterdir()}
    if not {record['overlay'], str(folder/'firmware-code.fd'), str(folder/'firmware-active.fd')} <= handles:
        raise ValueError('QEMU did not open the exact scratch disk and firmware files')
    socket_path = folder/'qga.sock'; info = socket_path.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError('QGA socket is not owned by this scratch identity')
    sockets = [line.split() for line in process.joinpath('net/unix').read_text().splitlines()[1:]]
    inodes = {fields[6] for fields in sockets if len(fields) == 8 and fields[7] == str(socket_path)}
    if len(inodes) != 1 or not {'socket:['+inode+']' for inode in inodes} <= handles:
        raise ValueError('QGA socket is not held by the actual QEMU process')
    if process.joinpath('stat').read_text().rsplit(')', 1)[1].split()[19] != launch['startTicks']:
        raise ValueError('QEMU process changed during identity check')
    return socket_path


def remaining(deadline):
    value = deadline-time.monotonic()
    if value <= 0:
        raise TimeoutError('absolute QGA deadline spent')
    return value


class BoundedAgent(GuestAgent):
    """Existing QGA protocol with absolute bounds even under continuous byte drip."""
    def __init__(self, path, timeout=30):
        self.deadline = time.monotonic()+timeout
        self.buffer = bytearray()
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(min(30, remaining(self.deadline)))
        try:
            self.sock.connect(path)
            self._sync()
        except BaseException:
            self.sock.close()
            raise

    def close(self):
        self.sock.close()

    def send(self, data):
        self.sock.settimeout(min(30, remaining(self.deadline)))
        self.sock.sendall(data)

    def line(self):
        while True:
            remaining(self.deadline)
            newline = self.buffer.find(b'\n')
            if newline >= 0:
                line = bytes(self.buffer[:newline+1]); del self.buffer[:newline+1]
                return line
            if len(self.buffer) > 1048576:
                raise ValueError('oversized QGA response line')
            self.sock.settimeout(min(30, remaining(self.deadline)))
            data = self.sock.recv(65536)
            if not data:
                raise RuntimeError('QGA socket closed')
            self.buffer.extend(data)

    def _sync(self):
        nonce = secrets.randbits(63)
        self.send(b'\xff'+json.dumps({'execute': 'guest-sync-delimited', 'arguments': {'id': nonce}}).encode()+b'\n')
        while True:
            line = self.line()
            if line.startswith(b'\xff'):
                try:
                    if json.loads(line[1:]).get('return') == nonce:
                        return
                except ValueError:
                    pass

    def request(self, execute, arguments=None):
        message = {'execute': execute}
        if arguments is not None:
            message['arguments'] = arguments
        self.send(json.dumps(message).encode()+b'\n')
        while True:
            response = json.loads(self.line())
            if 'error' in response:
                raise RuntimeError('QGA request failed')
            if 'return' in response:
                return response['return']

    def exec(self, path, args, exec_timeout=None):
        pid = self.request('guest-exec', {'path': path, 'arg': args, 'capture-output': True})['pid']
        while True:
            result = self.request('guest-exec-status', {'pid': pid})
            if result.get('exited'):
                if result.get('out-truncated') or result.get('err-truncated'):
                    raise ValueError('QGA process output truncated')
                return result.get('exitcode', 1), base64.b64decode(result.get('out-data', '')), base64.b64decode(result.get('err-data', ''))
            time.sleep(min(.25, remaining(self.deadline)))


def expected_helpers(kind, plan):
    if kind == 'windows':
        volume = plan['windowsVolume']
        return {volume+'\\wootc\\qa\\'+name: hashlib.sha256(b'\xef\xbb\xbf'+Path(__file__).with_name(name).read_text(encoding='utf-8-sig').replace('\r\n', '\n').replace('\n', '\r\n').encode()).hexdigest()
                for name in ('capture-windows.ps1', 'arm-classic.ps1')}
    paths = {ROOT/'payload/migration'/name: '/var/usrlocal/bin/'+name for name in ('wootc-esp-control', 'wootc-esp-sync')}
    paths.update({p: '/var/usrlocal/lib/wootc/'+p.name for p in (ROOT/'payload/migration/lib').glob('wootc_*.py')})
    paths.update({Path(__file__).with_name(n): '/var/usrlocal/lib/wootc-qa/'+n for n in ('capture.py', 'upgrade-classic.py', 'stage-classic-source.py', 'package-consumer.py')})
    hashes = {destination: hashlib.sha256(path.read_bytes()).hexdigest() for path, destination in paths.items()}
    if plan['identity']['deploymentKind'] == 'classic':
        policy_module = runpy.run_path(str(Path(__file__).with_name('package-policy.py')))
        policy = policy_module['build_policy'](json.loads(policy_module['PLAN'].read_text()), plan['scratchId'])
        policy_bytes = (json.dumps(policy, sort_keys=True)+'\n').encode()
        policy_hash = hashlib.sha256(policy_bytes).hexdigest()
        hashes['/var/lib/wootc/qa-upgrade/packages.json'] = policy_hash
        owner = {'scope': 'exclusive-classic-qa-root', 'scratchId': plan['scratchId'], 'policySha256': policy_hash}
        hashes['/var/lib/wootc/qa-upgrade/ownership.json'] = hashlib.sha256((json.dumps(owner)+'\n').encode()).hexdigest()
        for phase in policy['phases'].values():
            for entry in phase['packages']:
                hashes['/var/lib/wootc/qa-upgrade/'+entry['name']] = entry['sha256']
    pins = json.loads((ROOT/'docs/experiments/evidence/2026-09-27-classic-versioned-rpm/provenance.json').read_text())['verifierClosureHashes']
    hashes.update({'/var/usrlocal/lib/wootc/sbverify/'+n: value for n, value in pins.items()})
    return hashes


class Transport:
    def __init__(self, folder, record, connect=BoundedAgent, identity_check=check_vm, helper_policy=expected_helpers):
        self.folder, self.record = Path(folder), record
        self.connect, self.identity_check = connect, identity_check
        self.helper_policy = helper_policy
        self.run_id = secrets.token_hex(16)
        self.sequence = 0
        self.events = []
        self.ledger = self.folder/('qga-events-'+self.run_id+'.jsonl')
        self.fd = os.open(self.ledger, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)

    def close(self):
        os.close(self.fd)

    def event(self, kind, **facts):
        self.sequence += 1
        record = dict(sequence=self.sequence, monotonicNs=time.monotonic_ns(), kind=kind,
                      runId=self.run_id, **facts)
        os.write(self.fd, (json.dumps(record, sort_keys=True)+'\n').encode())
        os.fsync(self.fd)
        self.events.append(record)
        return record

    def execute(self, path, args, label, timeout=30, deadline=None):
        deadline = min(deadline, time.monotonic()+timeout) if deadline is not None else time.monotonic()+timeout
        socket = self.identity_check(self.folder, self.record)
        started = self.event('exec-start', label=label)
        agent = self.connect(str(socket), timeout=remaining(deadline))
        try:
            rc, stdout, stderr = agent.exec(path, args, exec_timeout=remaining(deadline))
        finally:
            agent.close()
        if len(stdout) > 262144 or len(stderr) > 65536:
            raise ValueError('bounded QGA output exceeded')
        self.event('exec-finish', label=label, startSequence=started['sequence'], exitCode=rc,
                   stdoutSha256=hashlib.sha256(stdout).hexdigest())
        if rc:
            raise ValueError('guest command failed: '+label)
        return stdout

    def verify_helpers(self, hashes, deadline):
        if not hashes:
            raise ValueError('missing exact guest helper hashes')
        socket = self.identity_check(self.folder, self.record)
        agent = self.connect(str(socket), timeout=remaining(deadline))
        try:
            for path, expected in hashes.items():
                remaining(deadline)
                handle = agent.request('guest-file-open', {'path': path, 'mode': 'r'})
                measured = hashlib.sha256(); total = 0
                try:
                    while True:
                        remaining(deadline)
                        response = agent.request('guest-file-read', {'handle': handle, 'count': 65536})
                        chunk = base64.b64decode(response.get('buf-b64', ''), validate=True)
                        total += len(chunk)
                        if response.get('count') != len(chunk) or total > 16777216:
                            raise ValueError('invalid or oversized QGA helper read')
                        measured.update(chunk)
                        if response.get('eof'):
                            break
                        if not chunk:
                            raise ValueError('QGA helper read made no progress')
                finally:
                    agent.request('guest-file-close', {'handle': handle})
                if measured.hexdigest() != expected:
                    raise ValueError('actual guest helper hash differs: '+path)
        finally:
            agent.close()
        self.event('helper-hashes-verified', count=len(hashes))

    def capture(self, os_kind, plan, prior=None, deadline=None):
        deadline = deadline if deadline is not None else time.monotonic()+60
        hashes = plan['helperHashesLinux' if os_kind == 'linux' else 'helperHashesWindows']
        if hashes != self.helper_policy(os_kind, plan):
            raise ValueError('guest helper closure is incomplete or differs from pinned source')
        self.verify_helpers(hashes, deadline)
        nonce = secrets.token_hex(32)
        if os_kind == 'linux':
            args = ['/var/usrlocal/lib/wootc-qa/capture.py', '--esp', plan['espMount'],
                    '--uuid', plan['identity']['hostEspUuid'], '--transport-nonce', nonce, '--mount-esp']
            if prior is not None:
                args += ['--old-hashes', '/var/lib/wootc/qa-upgrade/old-hashes.json']
            output = self.execute('/usr/bin/python3', args, 'linux-capture', deadline=deadline)
        else:
            # EncodedCommand avoids quoting or encoding guesses on Windows 5.1.
            volume = plan['windowsVolume']
            if len(volume) != 2 or not volume[0].isalpha() or volume[1] != ':':
                raise ValueError('explicit Windows root.disk volume required')
            command = "& '"+volume+"\\wootc\\qa\\capture-windows.ps1' -ScratchId '"+self.record['scratchId']+"' -AfterLinuxBootId '"+prior['observation']['bootId']+"' -Volume '"+volume+"' -TransportNonce '"+nonce+"'"
            output = self.execute('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand',
                                  base64.b64encode(command.encode('utf-16le')).decode()], 'windows-capture', deadline=deadline)
        data = json.loads(output)
        if data.get('transportNonce') != nonce or data['vmUuid'].lower() != self.record['vmUuid'].lower():
            raise ValueError('stale capture or wrong actual VM identity')
        if os_kind == 'windows' and data.get('os') != 'Windows_NT':
            raise ValueError('guest is not currently Windows')
        if os_kind == 'linux' and data.get('observation', {}).get('rootKind') != 'loop':
            raise ValueError('guest is not installed loop-root Linux')
        self.event('capture-verified', os=os_kind, bootId=data.get('observation', {}).get('bootId'),
                   nonceSha256=hashlib.sha256(nonce.encode()).hexdigest())
        return data

    def wait_capture(self, os_kind, plan, prior, seconds=600):
        deadline = time.monotonic()+seconds
        while time.monotonic() < deadline:
            try:
                data = self.capture(os_kind, plan, prior, deadline=deadline)
                if os_kind == 'windows' or data['observation']['bootId'] != prior['observation']['bootId']:
                    return data
            except (OSError, ValueError, RuntimeError, KeyError):
                pass
            time.sleep(min(1, max(0, deadline-time.monotonic())))
        raise ValueError('actual OS transition deadline exceeded')

    def bootstrap_classic(self, plan):
        windows = self.capture('windows', plan, {'observation': {'bootId': 'bootstrap'}})
        if windows['hostUuid'] != plan['identity']['hostUuid']:
            raise ValueError('actual Windows root.disk volume differs from producer')
        for role in ('host', 'system'):
            if windows.get('bitlocker', {}).get(role) != {'volumeStatus': 'FullyDecrypted', 'protectionStatus': 'Off', 'encryptionPercentage': 0}:
                raise ValueError('classic scratch requires observed unencrypted Windows volumes')
        nonce = secrets.token_hex(32)
        command = "& '"+plan['windowsVolume']+"\\wootc\\qa\\arm-classic.ps1' -VmUuid '"+self.record['vmUuid']+"' -EspPartitionGuid '"+plan['identity']['bootCurrent']['espPartitionGuid']+"' -LoaderPath '"+plan['identity']['bootCurrent']['loaderPath']+"' -TransportNonce '"+nonce+"'"
        output = self.execute('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', base64.b64encode(command.encode('utf-16le')).decode()], 'actual-windows-bcd-arm')
        armed = json.loads(output)
        if armed.get('transportNonce') != nonce or armed.get('os') != 'Windows_NT' or armed['vmUuid'].lower() != self.record['vmUuid'].lower():
            raise ValueError('stale BCD arm or wrong guest')
        self.event('windows-bcd-verified', bcdId=armed['bcdId'])
        try:
            self.execute('shutdown.exe', ['/r', '/t', '0'], 'windows-reboot', timeout=10)
        except (OSError, RuntimeError, ValueError):
            pass
        return self.wait_capture('linux', plan, {'observation': {'bootId': 'bootstrap'}})

    def reboot(self, boot, next_linux):
        # Side effects are issued once, with no timeout/reconnect replay.
        number = boot['observation']['bootCurrent']['bootNumber']
        if not isinstance(number, int) or not 0 <= number <= 65535:
            raise ValueError('invalid measured BootCurrent')
        if next_linux:
            self.execute('/usr/bin/efibootmgr', ['--bootnext', format(number, '04X')], 'arm-measured-linux')
        self.event('reboot-issued', fromBootId=boot['observation']['bootId'], nextLinux=next_linux)
        try:
            self.execute('/usr/bin/systemctl', ['reboot'], 'reboot', timeout=10)
        except (OSError, RuntimeError, ValueError):
            # Only a later distinct actual capture can resolve ambiguous reboot status.
            pass


def run(transport, plan, bootstrap=False):
    if plan['scratchId'] != transport.record['scratchId'] or plan['vmUuid'].lower() != transport.record['vmUuid'].lower():
        raise ValueError('plan belongs to another scratch VM')
    if transport.helper_policy is expected_helpers:
        raw_plan = (transport.folder/'plan.json').read_bytes()
        if hashlib.sha256(raw_plan).hexdigest() != transport.record['planSha256'] or json.loads(raw_plan) != plan:
            raise ValueError('orchestrator plan differs from frozen producer plan')
    if transport.helper_policy is expected_helpers and plan['identity']['deploymentKind'] == 'classic':
        source_pins = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for directory in (ROOT/'payload/migration', ROOT/'platform/dracut/99wootc-boot', Path(__file__).parent) for p in directory.rglob('*') if p.is_file() and p.suffix != '.pyc' and '__pycache__' not in p.parts}
        if plan.get('producerSourceHashes') != source_pins:
            raise ValueError('producer source provenance differs from complete pinned implementation')
    old = transport.bootstrap_classic(plan) if bootstrap else transport.capture('linux', plan)
    validate_firmware(old, plan, True)  # Measured baseline must match before source mutation.
    measured = old['observation']['bootCurrent']
    pinned = plan['identity']['bootCurrent']
    if measured['espPartitionGuid'].lower() != pinned['espPartitionGuid'].lower() or measured['loaderPath'].lower() != pinned['loaderPath'].lower():
        raise ValueError('first actual BootCurrent differs from producer ESP/loader')
    # Pin the boot number from this fresh execution, never from a marker or fixture.
    plan['identity']['bootCurrent'] = measured
    validate_initial(plan, old)  # Full measured old source/boot approval before upgrade.
    windows_hashes = plan['helperHashesWindows']
    if windows_hashes != transport.helper_policy('windows', plan):
        raise ValueError('Windows source closure is incomplete before upgrade')
    private_windows = {'/run/initramfs/wootc-host'+path[2:].replace('\\', '/'): expected for path, expected in windows_hashes.items()}
    transport.verify_helpers(private_windows, time.monotonic()+120)
    kind = old['observation']['deploymentKind']
    if kind == 'bootc':
        transport.execute('/usr/bin/bootc', ['upgrade'], 'real-bootc-upgrade', timeout=1800)
    elif kind == 'classic':
        # Producer stages SHA-bound public packages; verify bytes again inside guest.
        transport.execute('/usr/bin/python3', ['/var/usrlocal/lib/wootc-qa/upgrade-classic.py'],
                          'real-classic-package-upgrade', timeout=600)
    else:
        raise ValueError('unsupported actual deployment kind')
    transport.execute('/usr/bin/systemctl', ['start', 'wootc-esp-sync.service'], 'actual-esp-sync', timeout=180)
    transport.reboot(old, True)
    new = transport.wait_capture('linux', plan, old)
    transport.reboot(new, True)
    reboot = transport.wait_capture('linux', plan, new)
    # The QA baseline must retain Windows as its default boot target.
    transport.reboot(reboot, False)
    windows = transport.wait_capture('windows', plan, reboot)
    result = validate(plan, old, new, reboot, windows)
    actual = [e['os'] for e in transport.events if e['kind'] == 'capture-verified']
    if actual[-1:] != ['windows'] or len([e for e in actual if e == 'linux']) < 3:
        raise ValueError('actual execution chronology missing')
    production = transport.identity_check is check_vm and transport.helper_policy is expected_helpers
    result.update(firmwareStoreBindingVerified=production, chronologyVerified=True, firmwareAcceptance=production,
                  classicOsBootAcceptance=production and kind == 'classic', transportRunId=transport.run_id)
    result['scope'] = 'actual no-cut QGA/software run; no hardware power-cut claim' if production else 'QGA protocol order with injected fixture identity/OS/policy; no firmware or OS claim'
    # This proves the no-cut software run only. No hardware power-cut claim.
    for name, data in [('old', old), ('new', new), ('reboot', reboot), ('windows', windows), ('result', result)]:
        path = transport.folder/(transport.run_id+'-'+name+'.json')
        with path.open('x') as stream:
            json.dump(data, stream, sort_keys=True)
            stream.flush(); os.fsync(stream.fileno())
        path.chmod(0o600)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('scratch', type=Path)
    parser.add_argument('plan', type=Path)
    parser.add_argument('--bootstrap-classic', action='store_true')
    args = parser.parse_args()
    try:
        record = json.loads((args.scratch/'scratch.json').read_text())
        lock = os.open(args.scratch/'orchestrator.lock', os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        transport = Transport(args.scratch, record)
        try:
            print(json.dumps(run(transport, json.loads(args.plan.read_text()), args.bootstrap_classic), sort_keys=True))
        finally:
            transport.close()
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        parser.exit(1, 'orchestration refused: '+str(error)+'\n')
