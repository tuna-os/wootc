"""Consume complete pinned offline package sets only in a declared private QA root."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import shutil
import subprocess
import sys
import tempfile
import time


def execute(command, check=True, timeout=30, capture_output=False, env=None):
    deadline = time.monotonic()+timeout
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, start_new_session=True)
    output = {child.stdout: bytearray(), child.stderr: bytearray()}
    try:
        with selectors.DefaultSelector() as selector:
            for stream in output: selector.register(stream, selectors.EVENT_READ)
            while selector.get_map():
                remaining = deadline-time.monotonic()
                if remaining <= 0: raise subprocess.TimeoutExpired(command, timeout)
                for key, _ in selector.select(remaining):
                    data = os.read(key.fileobj.fileno(), 8192)
                    if not data: selector.unregister(key.fileobj); continue
                    output[key.fileobj].extend(data)
                    if sum(len(value) for value in output.values()) > 262144:
                        raise ValueError('package command output exceeds bound')
            result = child.wait(timeout=max(0, deadline-time.monotonic()))
        if check and result:
            raise subprocess.CalledProcessError(result, command, output=bytes(output[child.stdout]), stderr=bytes(output[child.stderr]))
        if not capture_output:
            sys.stdout.buffer.write(output[child.stdout]); sys.stderr.buffer.write(output[child.stderr])
        return subprocess.CompletedProcess(command, result, bytes(output[child.stdout]), bytes(output[child.stderr]))
    finally:
        # This group belongs to this invocation; it cannot include an existing service.
        try: os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        child.wait()
        for stream in output: stream.close()


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def apt_archive_name(entry):
    # APT pkgAcqArchive/QuoteString canonical archive identity, including epochs.
    version = entry['version']
    if not isinstance(version, str) or not re.fullmatch(r'(?:[0-9]+:)?[0-9][A-Za-z0-9.+~\-]*', version):
        raise ValueError('unsupported package version for canonical offline cache')
    def quoted(value, bad):
        return ''.join('%%%02x' % ord(char) if char in bad or char == '%' or
                       ord(char) <= 32 or ord(char) >= 127 else char for char in value)
    return quoted(entry['package'], '_:')+'_'+quoted(version, '_:')+'_'+quoted(entry['architecture'], '_:.')+'.deb'


def inventory(run, allowed_retired=None):
    result = run(['/usr/bin/dpkg-query', '-W', '-f', '${binary:Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n'],
                 check=True, timeout=30, capture_output=True)
    if len(result.stdout) > 262144:
        raise ValueError('dpkg inventory exceeds bound')
    rows = {}; seen = set()
    for line in result.stdout.decode().splitlines():
        parts = line.split('\t')
        if len(parts) != 4:
            raise ValueError('dpkg has partial or malformed package state')
        name = parts[0].split(':', 1)[0]
        if not re.fullmatch('[a-z0-9][a-z0-9+.-]*', name) or name in seen or not parts[1] or parts[2] not in ('amd64', 'all'):
            raise ValueError('unsupported or duplicate dpkg package identity')
        seen.add(name)
        if parts[3] == 'config-files' and (allowed_retired or {}).get(name) == {'version': parts[1], 'architecture': parts[2]}:
            continue
        if parts[3] != 'installed':
            raise ValueError('dpkg has partial or unapproved retired package state')
        rows[name] = {'version': parts[1], 'architecture': parts[2]}
    if not rows:
        raise ValueError('dpkg inventory absent')
    return rows


def checked_policy(folder, phase):
    folder = Path(folder)
    if phase not in ('old', 'new') or folder.is_symlink() or folder.stat().st_uid != os.geteuid() or folder.stat().st_mode & 0o022:
        raise ValueError('package root is not private caller-owned QA state')
    policy_path, owner_path = folder/'packages.json', folder/'ownership.json'
    for path in (policy_path, owner_path):
        if path.is_symlink() or not path.is_file() or path.stat().st_uid != os.geteuid() or path.stat().st_mode & 0o022 or path.stat().st_size > 262144:
            raise ValueError('unowned package policy or scratch declaration')
    policy = json.loads(policy_path.read_text())
    owner = json.loads(owner_path.read_text())
    if (type(policy.get('schemaVersion')) is not int or policy['schemaVersion'] != 1 or policy.get('manager') != 'dpkg' or
            owner.get('scope') != 'exclusive-classic-qa-root' or
            not re.fullmatch('[0-9a-f]{32}', owner.get('scratchId', '')) or
            owner['scratchId'] != policy.get('scratchId') or
            owner.get('policySha256') != digest(policy_path)):
        raise ValueError('package policy is not bound to this owned QA root')
    packages = policy['phases'][phase]['packages']
    allowed = policy['phases'][phase]['allowedRemovals']
    if not packages or len(packages) > 256 or set(allowed) - ({'initramfs-tools', 'cloud-initramfs-growroot'} if phase == 'old' else set()):
        raise ValueError('missing bundle or unapproved scratch package removals')
    seen = set()
    for entry in packages:
        if (set(entry) != {'name', 'package', 'version', 'architecture', 'sha256'} or
                Path(entry['name']).name != entry['name'] or not entry['name'].endswith('.deb') or
                not re.fullmatch('[a-z0-9][a-z0-9+.-]*', entry['package']) or entry['package'] in seen or
                not entry['version'] or entry['architecture'] not in ('amd64', 'all') or
                not re.fullmatch('[0-9a-f]{64}', entry['sha256'])):
            raise ValueError('incomplete or ambiguous offline bundle identity')
        seen.add(entry['package'])
    return policy


def validate_simulation(output, selected):
    """Bind every apt mutation observation to the complete approved inventory delta."""
    before, after = selected['beforeInventory'], selected['afterInventory']
    expected_installs = {name: identity for name, identity in after.items()
                         if before.get(name) != identity}
    expected_removals = set(before) - set(after)
    if expected_removals != set(selected['allowedRemovals']):
        raise ValueError('approved removal set differs from inventory transition')
    pinned = {entry['package']: {'version': entry['version'], 'architecture': entry['architecture']}
              for entry in selected['packages']}
    if any(pinned.get(name) != identity for name, identity in expected_installs.items()):
        raise ValueError('approved transition is not bound to the frozen bundle')
    installs, removals, configurations = {}, set(), {}
    # APT appends a transient broken-dependency list while ordering a plan.
    # These annotations describe solver state, not additional mutations.
    annotation = r'(?: \[(?:[a-z0-9][a-z0-9+.-]*:(?:amd64|all) )*\])?'
    for line in output.splitlines():
        # Human summaries are not mutation evidence. Reserved mutation words must
        # parse completely; a truncated observation cannot become a summary.
        kind = line.lstrip().split(maxsplit=1)[0] if line.strip() else ''
        if kind not in ('Inst', 'Conf', 'Remv'):
            continue
        if kind == 'Remv':
            match = re.fullmatch(r'Remv ([a-z0-9][a-z0-9+.-]*)(?::(amd64|all))? \[([^]\s]+)\]'+annotation, line)
            if not match:
                raise ValueError('unknown apt removal observation')
            name, qualifier, version = match.groups()
            identity = before.get(name)
            if (name in removals or identity is None or identity['version'] != version or
                    (qualifier is not None and qualifier != identity['architecture'])):
                raise ValueError('duplicate or mismatched apt removal observation')
            removals.add(name)
            continue
        match = re.fullmatch(
            r'(?:Inst|Conf) ([a-z0-9][a-z0-9+.-]*)(?::(amd64|all))?'
            r'(?: \[([^]\s]+)\])? \(([^()\s]+) [^()\n]*\[(amd64|all)\]\)'+annotation, line)
        if not match:
            raise ValueError('unknown apt install or configuration observation')
        name, qualifier, previous, version, architecture = match.groups()
        identity = {'version': version, 'architecture': architecture}
        observed = installs if kind == 'Inst' else configurations
        if (name in observed or expected_installs.get(name) != identity or
                (qualifier is not None and qualifier != architecture) or
                (previous is not None and (kind != 'Inst' or before.get(name, {}).get('version') != previous))):
            raise ValueError('duplicate or unapproved apt mutation observation')
        observed[name] = identity
    if installs != expected_installs or removals != expected_removals:
        raise ValueError('apt simulation does not observe the complete approved transition')
    if any(installs.get(name) != identity for name, identity in configurations.items()):
        raise ValueError('apt configuration lacks its approved installation')
    simulated = dict(before)
    for name in removals:
        del simulated[name]
    simulated.update(installs)
    if simulated != after:
        raise ValueError('apt simulation result differs from approved inventory')


def consume(folder=Path('/var/lib/wootc/qa-upgrade'), phase='new', run=execute, before_install=None):
    original_run=run
    def run(command, **kwargs):
        try:return original_run(command, **kwargs)
        except subprocess.CalledProcessError as error:
            error.wootc_phase=phase
            error.wootc_operation='apt-simulate' if '--simulate' in command else ('apt-install' if command[0]=='/usr/bin/apt-get' and 'install' in command else 'package-query')
            raise
    folder = Path(folder)
    policy = checked_policy(folder, phase)
    selected = policy['phases'][phase]
    retired = {name: policy['phases']['old']['beforeInventory'][name]
               for name in policy['phases']['old']['allowedRemovals']}
    # A separate lock prevents two QA consumers from racing their inventory gate.
    descriptor = os.open(folder/'package.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if inventory(run, retired) != selected['beforeInventory']:
            raise ValueError('actual before-mutation dpkg inventory differs')
        with tempfile.TemporaryDirectory(prefix='offline-bundle-', dir=folder) as temporary:
            archives = Path(temporary)/'archives'; archives.mkdir(mode=0o700)
            (archives/'partial').mkdir(mode=0o700)
            frozen = []; frozen_facts = []; cache_names = set()
            for entry in selected['packages']:
                source = folder/entry['name']
                if source.is_symlink() or not source.is_file() or digest(source) != entry['sha256']:
                    raise ValueError('staged package hash differs or package missing')
                cache_name = apt_archive_name(entry)
                if cache_name in cache_names: raise ValueError('ambiguous canonical archive cache identity')
                cache_names.add(cache_name)
                target = archives/cache_name
                with source.open('rb') as reader, target.open('xb') as writer:
                    shutil.copyfileobj(reader, writer); writer.flush(); os.fsync(writer.fileno())
                target.chmod(0o400)
                if digest(source) != entry['sha256'] or digest(target) != entry['sha256']:
                    raise ValueError('staged package changed while freezing')
                result = run(['/usr/bin/dpkg-deb', '--show', '--showformat=${Package}\t${Version}\t${Architecture}\n', str(target)],
                             check=True, timeout=30, capture_output=True)
                if len(result.stdout) > 4096 or result.stdout.decode().strip().split('\t') != [entry['package'], entry['version'], entry['architecture']]:
                    raise ValueError('package control identity differs from pinned bundle')
                frozen.append(str(target))
                facts=target.lstat()
                frozen_facts.append((facts.st_dev,facts.st_ino,facts.st_size,facts.st_mtime_ns))
            empty_lists = Path(temporary)/'lists'; empty_lists.mkdir(mode=0o700)
            changes = [path for path, entry in zip(frozen, selected['packages'])
                       if selected['beforeInventory'].get(entry['package']) !=
                       {'version': entry['version'], 'architecture': entry['architecture']}]
            if not changes:
                raise ValueError('offline phase has no actual package version changes')
            command = ['/usr/bin/apt-get', '-o', 'Dir::Etc::sourcelist=/dev/null', '-o', 'Dir::Etc::sourceparts=-',
                       '-o', 'Dir::State::lists='+str(empty_lists),
                       '-o', 'Dir::Cache::archives='+str(archives), '--no-download',
                       '--no-install-recommends', '--allow-downgrades', '--yes', 'install']+changes
            result = run(command[:1]+['--simulate']+command[1:], check=True, timeout=60, capture_output=True,
                         env=dict(os.environ, LC_ALL='C'))
            if len(result.stdout) > 262144:
                raise ValueError('apt simulation exceeds bound')
            validate_simulation(result.stdout.decode(), selected)
            if inventory(run, retired) != selected['beforeInventory']:
                raise ValueError('dpkg inventory changed across offline preflight')
            if checked_policy(folder, phase) != policy:
                raise ValueError('QA policy changed across preflight')
            if before_install is not None: before_install()
            for path, entry, retained in zip(frozen, selected['packages'], frozen_facts):
                current=Path(path).lstat()
                if (Path(path).is_symlink() or not Path(path).is_file() or current.st_uid != os.geteuid() or
                        current.st_mode & 0o222 or current.st_nlink != 1 or
                        (current.st_dev,current.st_ino,current.st_size,current.st_mtime_ns) != retained or
                        digest(path) != entry['sha256']):
                    raise ValueError('frozen bundle changed before install')
            run(command, check=True, timeout=600, env=dict(os.environ, DEBIAN_FRONTEND='noninteractive'))
            if inventory(run, retired) != selected['afterInventory']:
                raise ValueError('actual installed package inventory differs from approved result')
    return {'installedPhase': phase, 'scratchId': policy['scratchId'], 'networkPackageAcquisition': False,
            'scope': 'package consumer result only; no OS or firmware boot acceptance'}


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=('old', 'new'))
    args = parser.parse_args()
    print(json.dumps(consume(phase=args.phase), sort_keys=True))
