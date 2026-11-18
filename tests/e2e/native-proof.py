#!/usr/bin/env python3
"""Assemble bound raw native observations; the soak ledger remains the authority."""
import argparse
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('soak_ledger', ROOT / 'tools/soak/ledger.py')
ledger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ledger)


package_spec = importlib.util.spec_from_file_location('native_package', ROOT / 'tests/e2e/native-package.py')
native_package = importlib.util.module_from_spec(package_spec)
package_spec.loader.exec_module(native_package)


def require_package_source(package, sha):
    build, _, _ = native_package.check(package)
    if build != sha:
        raise ValueError('Native package buildId differs from proof source SHA')

def load(path):
    if path.stat().st_size > ledger.MAX_PROOF:
        raise ValueError('Oversized native proof input')
    return json.loads(path.read_text(encoding='utf-8-sig'))


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def identity(package):
    sha = os.environ['GITHUB_SHA']
    if not ledger.SHA.fullmatch(sha):
        raise ValueError('Native proof requires a full source SHA')
    require_package_source(package, sha)
    rows = subprocess.check_output(['git', 'ls-tree', '-rz', '--full-tree', sha], cwd=ROOT).split(b'\0')
    files = []
    for row in filter(None, rows):
        metadata, path = row.split(b'\t', 1)
        _, kind, blob = metadata.decode().split()
        if kind == 'blob':
            files.append((path.decode(), blob))
    result = {'artifactSha256': ledger.digest((package / 'Wootc.Shell.exe').read_bytes())}
    for field, prefixes in [('shellTreeSha256', ('shell/',)), ('transportTreeSha256', ('app/', 'tests/e2e/qga.py'))]:
        selected = sorted((path, blob) for path, blob in files if path.startswith(prefixes))
        if not selected:
            raise ValueError('Source identity scope empty')
        result[field] = ledger.digest(json.dumps(selected, separators=(',', ':')).encode())
    return dict(runId=int(os.environ['GITHUB_RUN_ID']), runAttempt=int(os.environ['GITHUB_RUN_ATTEMPT']),
                sourceSha=sha, identity=result, startedAt=dt.datetime.now(dt.timezone.utc).isoformat())


def assemble(directory):
    context = load(directory / 'context.json')
    facts = load(directory / 'installed-boot-observation.json')
    observations = []
    for journey, required in ledger.REQUIRED.items():
        observation = load(directory / (journey + '.observation.json'))
        if observation['journey'] != journey:
            raise ValueError('Journey identity differs')
        expected = {'InstalledBootSource': facts['sourceImage'], 'InstalledBootKernel': facts['kernel'],
                    'InstalledBootBridge': facts['bridge'], 'InstalledBootId': facts['bootId']}
        observation['checks'] = [dict(automationId=control, property=prop, expected=literal if literal is not None else expected[control])
                                 for control, (prop, literal) in required.items()]
        observations.append(observation)
    proof = dict(schemaVersion=1, shell='winui3', observer='windows-uia',
        runId=context['runId'], runAttempt=context['runAttempt'], sourceSha=context['sourceSha'], identity=context['identity'],
        processName='Wootc.Shell.exe', processImageSha256=context['identity']['artifactSha256'],
        installedBootId=facts['bootId'], observations=observations)
    save(directory / 'native-gui-proof.json', proof)
    validate(directory, 'all')


def validate(directory, section):
    context = load(directory / 'context.json')
    proof = load(directory / 'native-gui-proof.json')
    files = {'native-gui-proof.json', 'installed-boot-observation.json', 'windows-current-observation.json'}
    for observation in proof['observations']:
        for field in ('uiaFile', 'framebufferFile'):
            name = observation[field]
            if not isinstance(name, str) or '/' in name or '\\' in name or name in ('.', '..'):
                raise ValueError('Unsafe native proof path')
            files.add(name)
    if sum((directory / name).stat().st_size for name in files) > ledger.MAX_PROOF:
        raise ValueError('Expanded native proof exceeds ledger bound')
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
        for name in sorted(files):
            output.writestr(name, (directory / name).read_bytes())
    data = archive.getvalue()
    # Local validation uses real capture interval. GitHub collector revalidates
    # independently using API run timestamps and the uploaded archive digest.
    run = dict(id=context['runId'], run_attempt=context['runAttempt'], head_sha=context['sourceSha'],
               run_started_at=context['startedAt'], updated_at=dt.datetime.now(dt.timezone.utc).isoformat())
    artifact = dict(id=0, digest='sha256:' + ledger.digest(data), workflow_run=dict(id=run['id'], head_sha=run['head_sha'], head_branch='main'))
    ledger.verify_proof(data, run, artifact)
    for observation in proof['observations']:
        raw = load(directory / observation['uiaFile'])
        if raw['processName'] != 'Wootc.Shell.exe' or raw['processPath'] != context['packagePath'] or raw['sourceSha'] != context['sourceSha']:
            raise ValueError('Native process identity differs')
    if section == 'identity':
        if ledger.digest((ROOT / 'tests/e2e/wootc-files/native-shell/Wootc.Shell.exe').read_bytes()) != proof['identity']['artifactSha256']:
            raise ValueError('Packaged executable differs from observed process')
    print('Validated native proof: ' + section)


def validate_summary(directory, record_path):
    """Non-soak native acceptance: actual UIA against retained live Linux facts."""
    context = load(directory / 'context.json')
    current = load(record_path)['current']
    bridge = current['bridge']
    expected = {
        'InstalledBootSource': current['image'].get('sourceRef') or current['image']['ref'],
        'InstalledBootKernel': current['kernel'],
        'InstalledBootBridge': 'boundFolders={};matchedUsers={};bitlockerUnlocked={}'.format(
            bridge['boundFolders'], bridge['matchedUsers'], str(bridge['bitlockerUnlocked']).lower()),
        'InstalledBootId': current['bootId'],
    }
    for journey in ('installed-boot-summary', 'windows-return'):
        observation = load(directory / (journey + '.observation.json'))
        raw = load(directory / (journey + '.uia.json'))
        frame = (directory / (journey + '.png')).read_bytes()
        if (not frame.startswith(b'\x89PNG\r\n\x1a\n') or ledger.digest(frame) != observation['framebufferSha256']
                or observation['journey'] != journey or raw['capturedAt'] != observation['capturedAt']):
            raise ValueError('Native framebuffer/UIA observation differs')
        if (any(raw[key] != context[key] for key in ('runId', 'runAttempt', 'sourceSha'))
                or raw['processImageSha256'] != context['identity']['artifactSha256']
                or raw['processPath'] != context['packagePath'] or raw['processName'] != 'Wootc.Shell.exe'):
            raise ValueError('Native summary process/run identity differs')
        required = expected if journey == 'installed-boot-summary' else {'WindowsReturnStatus': 'Windows is ready'}
        for control_id, value in required.items():
            matches = [control for control in raw['controls'] if control['automationId'] == control_id]
            prop = 'value' if journey == 'installed-boot-summary' else 'name'
            if len(matches) != 1 or not matches[0]['visible'] or not matches[0]['enabled'] or matches[0].get(prop) != value:
                raise ValueError('Native summary does not render current Linux fact: ' + control_id)
    windows = load(directory / 'windows-current-observation.json')
    if (windows['observer'] != 'windows-cim' or not windows['version']
            or any(windows[key] != context[key] for key in ('runId', 'runAttempt', 'sourceSha'))
            or dt.datetime.fromisoformat(windows['bootTime'].replace('Z', '+00:00')) <=
               dt.datetime.fromisoformat(current['writtenAt'].replace('Z', '+00:00'))):
        raise ValueError('Native summary lacks the actual subsequent Windows boot')
    print('Validated native summary against live Linux observation (not soak proof)')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    init = sub.add_parser('init')
    init.add_argument('directory', type=Path)
    init.add_argument('package', type=Path)
    for command in ('assemble', 'identity', 'journeys', 'frames'):
        sub.add_parser(command).add_argument('directory', type=Path)
    summary_init = sub.add_parser('summary-init')
    summary_init.add_argument('directory', type=Path)
    summary_init.add_argument('package', type=Path)
    summary_init.add_argument('run_id')
    summary_init.add_argument('source_sha')
    summary = sub.add_parser('summary')
    summary.add_argument('directory', type=Path)
    summary.add_argument('record_path', type=Path)
    args = parser.parse_args()
    if args.command in ('init', 'summary-init'):
        args.directory.mkdir(parents=True, exist_ok=False)
        if args.command == 'init':
            context = identity(args.package)
        else:
            if not ledger.SHA.fullmatch(args.source_sha):
                raise ValueError('Native summary source build identity missing')
            require_package_source(args.package, args.source_sha)
            context = dict(runId=args.run_id, runAttempt=None, sourceSha=args.source_sha,
                           identity={'artifactSha256': ledger.digest((args.package / 'Wootc.Shell.exe').read_bytes())})
        save(args.directory / 'context.json', context)
    elif args.command == 'assemble':
        assemble(args.directory)
    elif args.command == 'summary':
        validate_summary(args.directory, args.record_path)
    else:
        validate(args.directory, args.command)


if __name__ == '__main__':
    main()
