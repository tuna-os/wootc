#!/usr/bin/env python3
"""GitHub-native soak evidence collection. No VM action and no implied start."""
import argparse
import datetime as dt
import hashlib
import io
import json
import re
import subprocess
import zipfile
from pathlib import Path

SHA = re.compile(r'^[0-9a-f]{40}$')
HASH = re.compile(r'^[0-9a-f]{64}$')
BOOT_ID = re.compile(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$')
PREREQUISITES = {211, 178, 203, *range(229, 235), 323}
REQUIRED = {
    'install-confirmation': {'InstallConfirmation': ('name', 'Ready to install')},
    'installed-boot-summary': {'InstalledBootSource': ('value', None), 'InstalledBootKernel': ('value', None),
                               'InstalledBootBridge': ('value', None)},
    'windows-return': {'WindowsReturnStatus': ('name', 'Windows is ready')},
}
NATIVE_JOB = 'native-shell GUI acceptance'
NATIVE_STEPS = {'Verify native process identity', 'Assert native UIA journeys', 'Capture native framebuffer'}
RC_REQUIREMENTS = {'**Code signing**:', 'Signed-build plumbing', 'Try-in-VM (#178):',
                   'Program-migrator plugin architecture (#203):', 'Docs pass:', 'Field-report corpus review:'}
MAX_PROOF = 8 * 1024 * 1024
MAX_PRODUCT = 128 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def has_run_link(body, url):
    return re.search(re.escape(url) + r'(?![0-9/])', body or '') is not None


def utc_date(value):
    return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(dt.timezone.utc).date().isoformat()


def verify_proof(data, run, artifact):
    """Only a current-run native UIA capture can qualify; never a browser receipt.

    This is the contract for the future native producer. Existing Wails artifacts
    cannot satisfy it. Raw UIA control values and a hashed framebuffer must agree
    with each semantic assertion. The producer must run inside the native gate.
    """
    if len(data) > MAX_PROOF or artifact.get('expired'):
        raise ValueError('expired or oversized native proof')
    provenance = artifact.get('workflow_run', {})
    if provenance.get('id') != run['id'] or provenance.get('head_sha') != run['head_sha'] or provenance.get('head_branch') != 'main':
        raise ValueError('artifact belongs to another run')
    if artifact.get('digest') != 'sha256:' + digest(data):
        raise ValueError('GitHub artifact digest differs')
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        if sum(e.file_size for e in entries) > MAX_PROOF:
            raise ValueError('expanded proof too large')
        names = [e.filename for e in entries]
        if len(names) != len(set(names)) or any('/' in n or '\\' in n or n in {'.', '..'} for n in names):
            raise ValueError('ambiguous or unsafe proof archive')
        files = {e.filename: archive.read(e) for e in entries}
    proof = json.loads(files['native-gui-proof.json'])
    if proof.get('schemaVersion') != 1 or proof.get('shell') != 'winui3' or proof.get('observer') != 'windows-uia':
        raise ValueError('native Windows UI Automation proof required')
    if proof.get('runId') != run['id'] or proof.get('runAttempt') != run['run_attempt'] or proof.get('sourceSha') != run['head_sha']:
        raise ValueError('proof source/run attempt mismatch')
    identity = proof.get('identity', {})
    for field in ['artifactSha256', 'shellTreeSha256', 'transportTreeSha256']:
        if not HASH.fullmatch(identity.get(field, '')):
            raise ValueError('missing artifact/shell/transport identity')
    # The packaged executable hash must equal the observed native process image.
    if proof.get('processImageSha256') != identity['artifactSha256'] or proof.get('processName') != 'Wootc.Shell.exe':
        raise ValueError('native process and shipped artifact differ')
    facts = json.loads(files['installed-boot-observation.json'])
    if facts.get('runId') != run['id'] or facts.get('runAttempt') != run['run_attempt'] or facts.get('sourceSha') != run['head_sha'] or facts.get('observer') != 'linux-qga' or facts.get('uname') != 'Linux':
        raise ValueError('independent installed Linux observation missing')
    began = dt.datetime.fromisoformat(run['run_started_at'].replace('Z', '+00:00'))
    ended = dt.datetime.fromisoformat(run['updated_at'].replace('Z', '+00:00'))
    fact_time = dt.datetime.fromisoformat(facts['capturedAt'].replace('Z', '+00:00'))
    if not began <= fact_time <= ended:
        raise ValueError('Stale installed Linux observation')
    if not BOOT_ID.fullmatch(facts.get('bootId', '')) or facts['bootId'] != facts.get('liveBootId') or facts['bootId'] != proof.get('installedBootId'):
        raise ValueError('Installed record does not match current Linux boot identity')
    boot_values = {'InstalledBootSource': facts.get('sourceImage'), 'InstalledBootKernel': facts.get('kernel'),
                   'InstalledBootBridge': facts.get('bridge')}
    observed = proof.get('observations', [])
    if {o.get('journey') for o in observed} != set(REQUIRED) or len(observed) != len(REQUIRED):
        raise ValueError('missing or duplicate native journey')
    for observation in observed:
        timestamp = dt.datetime.fromisoformat(observation['capturedAt'].replace('Z', '+00:00'))
        began = dt.datetime.fromisoformat(run['run_started_at'].replace('Z', '+00:00'))
        ended = dt.datetime.fromisoformat(run['updated_at'].replace('Z', '+00:00'))
        if not began <= timestamp <= ended:
            raise ValueError('stale framebuffer/UIA observation')
        frame = files[observation['framebufferFile']]
        if not frame.startswith(b'\x89PNG\r\n\x1a\n') or digest(frame) != observation['framebufferSha256']:
            raise ValueError('framebuffer absent or mismatched')
        tree = json.loads(files[observation['uiaFile']])
        if tree.get('processImageSha256') != identity['artifactSha256'] or tree.get('runId') != run['id']:
            raise ValueError('UIA capture belongs to another process/run')
        if tree.get('runAttempt') != run['run_attempt'] or tree.get('capturedAt') != observation['capturedAt']:
            raise ValueError('Raw UIA capture attempt or timestamp differs')
        if observation['journey'] == 'installed-boot-summary' and fact_time > timestamp:
            raise ValueError('Linux facts postdate the rendered summary')
        controls = tree.get('controls', [])
        checks = observation.get('checks', [])
        required = REQUIRED[observation['journey']]
        if {c.get('automationId') for c in checks} != set(required) or len(checks) != len(required):
            raise ValueError('required native semantic controls absent')
        for check in checks:
            matches = [c for c in controls if c.get('automationId') == check.get('automationId')]
            if len(matches) != 1 or not matches[0].get('visible') or not matches[0].get('enabled'):
                raise ValueError('control missing, ambiguous, hidden or disabled')
            if check.get('property') not in {'name', 'value', 'toggleState'} or 'expected' not in check:
                raise ValueError('invalid semantic assertion')
            prop, literal = required[check['automationId']]
            if check['property'] != prop or (literal is not None and check['expected'] != literal):
                raise ValueError('native journey assertion differs from required contract')
            if literal is None and (not isinstance(check['expected'], str) or not check['expected'].strip() or check['expected'] != boot_values[check['automationId']]):
                raise ValueError('installed boot facts are empty')
            if matches[0].get(check['property']) != check['expected']:
                raise ValueError('rendered native control value differs')
    return {**identity, 'proofArtifactId': artifact['id'], 'proofArchiveSha256': digest(data),
            'proofDigest': artifact.get('digest'), 'shell': proof['shell'], 'semanticProof': True}


def verify_product(data, run, artifact, identity):
    provenance = artifact.get('workflow_run', {})
    if len(data) > MAX_PRODUCT or artifact.get('expired') or provenance.get('id') != run['id'] or provenance.get('head_sha') != run['head_sha'] or provenance.get('head_branch') != 'main':
        raise ValueError('Product artifact provenance differs')
    if artifact.get('digest') != 'sha256:' + digest(data):
        raise ValueError('Product artifact archive digest differs')
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        matches = [e for e in archive.infolist() if e.filename == 'Wootc.Shell.exe']
        if len(matches) != 1 or matches[0].file_size > MAX_PRODUCT:
            raise ValueError('Actual packaged native shell is absent or ambiguous')
        executable = archive.read(matches[0])
    if not executable.startswith(b'MZ') or digest(executable) != identity['artifactSha256']:
        raise ValueError('Observed native process differs from packaged executable')
    return {'productArtifactId': artifact['id'], 'productArchiveSha256': digest(data),
            'productDigest': artifact['digest']}


def prerequisites(config, issues):
    if config.get('phaseDIssue') != 345 or config.get('rcIssue') != 212:
        return False, 'phase D and RC authority must be recorded'
    ids = set(config.get('prerequisiteIssues', []))
    if not PREREQUISITES.issubset(ids):
        return False, 'missing RC prerequisite authorities'
    if any(issues.get(i, {}).get('state') != 'closed' for i in ids | {345}):
        return False, 'phase D or RC prerequisites remain open'
    start = config.get('startDate')
    if start and any(not issues[i].get('closed_at') or dt.datetime.fromisoformat(issues[i]['closed_at'].replace('Z', '+00:00')) > dt.datetime.combine(dt.date.fromisoformat(start), dt.time(), dt.timezone.utc) for i in ids | {345}):
        return False, 'Start predates prerequisite closure'
    rc = issues.get(212, {}).get('body', '')
    checklist = re.findall(r'^- \[([ xX])\] (.+)$', rc, re.M)
    if not all(any(mark.lower() == 'x' and text.startswith(required) for mark, text in checklist) for required in RC_REQUIREMENTS) or any(mark == ' ' and not text.startswith('**Soak starts**:') for mark, text in checklist):
        return False, 'RC checklist is incomplete'
    return True, ''


def summarize(rows, config, issues, today):
    start = config.get('startDate')
    ready, reason = prerequisites(config, issues)
    if start is None:
        return {'started': False, 'valid': False, 'streak': 0, 'reason': 'No soak start recorded'}
    start_day = dt.date.fromisoformat(start)
    if start_day > today or not ready:
        return {'started': False, 'valid': False, 'streak': 0, 'reason': reason or 'Start is in the future'}
    relevant = [r for r in rows if r['event'] == 'schedule' and r['date'] >= start]
    by_day = {}
    for row in sorted(relevant, key=lambda r: (r['date'], r.get('startedAt', ''), r['runId'], r['runAttempt'])):
        by_day.setdefault(row['date'], []).append(row)
    streak, identity, invalid = 0, None, False
    day = start_day
    # A day still in progress cannot supply a completed daily result.
    while day < today:
        attempts = by_day.get(day.isoformat(), [])
        if not attempts:
            streak, identity = 0, None
        else:
            for row in attempts:
                if row['verdict'] != 'success':
                    streak, identity = 0, None
                    if not row.get('diagnosisIssue'):
                        invalid = True
                elif not row.get('eligible'):
                    streak, identity = 0, None
                else:
                    current = (row['shellTreeSha256'], row['transportTreeSha256'])
                    if identity is not None and identity != current:
                        streak = 0
                    identity = current
            # A retry may supply the day's final green, but never erase a red.
            final = attempts[-1]
            if final.get('eligible') and final['verdict'] == 'success':
                streak += 1
        day += dt.timedelta(days=1)
    return {'started': True, 'valid': not invalid, 'streak': 0 if invalid else streak,
            'reason': 'Unexplained red since start' if invalid else '', 'startDate': start,
            'throughDate': (today - dt.timedelta(days=1)).isoformat()}


class GitHub:
    def __init__(self, repo):
        self.repo = repo

    def api(self, path, binary=False):
        output = subprocess.check_output(['gh', 'api', path], timeout=120)
        return output if binary else json.loads(output)

    def pages(self, path, key):
        result = []
        for page in range(1, 101):
            response = self.api(f'{path}{"&" if "?" in path else "?"}per_page=100&page={page}')
            data = response[key] if key else response
            result.extend(data)
            if len(data) < 100:
                return result
        raise ValueError('GitHub pagination bound reached; cannot silently omit attempts')

    def issue(self, number):
        return self.api(f'repos/{self.repo}/issues/{number}')


def collect(api, old, config, today):
    # Initial import is bounded to 90 days. Retained rows are never dropped.
    since = today - dt.timedelta(days=90)
    runs = api.pages(f'repos/{api.repo}/actions/workflows/e2e-gui.yml/runs?created=>={since.isoformat()}', 'workflow_runs')
    rows = {(r['runId'], r['runAttempt']): r for r in old}
    issues = {i: api.issue(i) for i in set(config['prerequisiteIssues']) | {345, 212}}
    for listed in runs:
        if listed['status'] != 'completed':
            continue
        # Preserve every rerun attempt: final workflow state must not hide reds.
        for attempt in range(1, listed['run_attempt'] + 1):
            key = (listed['id'], attempt)
            row = rows.get(key)
            if row is None:
                run = api.api(f'repos/{api.repo}/actions/runs/{listed["id"]}/attempts/{attempt}')
                if run['run_attempt'] != attempt or run['id'] != listed['id']:
                    raise ValueError('GitHub attempt identity mismatch')
                row = {'runId': run['id'], 'runAttempt': attempt, 'date': utc_date(run['run_started_at']),
                       'startedAt': run['run_started_at'], 'sourceSha': run['head_sha'], 'event': run['event'], 'verdict': run['conclusion'],
                       'runUrl': run['html_url'], 'eligible': False, 'reason': 'Native semantic proof missing',
                       'autoReleaseTag': None}
                if run['head_branch'] != 'main' or run.get('head_repository', {}).get('full_name') != api.repo:
                    row['reason'] = 'Not a run from repository main'
                elif not SHA.fullmatch(run['head_sha']):
                    row['reason'] = 'Invalid source SHA'
                elif run['conclusion'] == 'success':
                    compare = api.api(f'repos/{api.repo}/compare/{run["head_sha"]}...main')
                    if compare['status'] not in {'ahead', 'identical'}:
                        row['reason'] = 'Source commit is not in main history'
                        rows[key] = row
                        continue
                    jobs = api.pages(f'repos/{api.repo}/actions/runs/{run["id"]}/attempts/{attempt}/jobs', 'jobs')
                    native = [j for j in jobs if j['name'] == NATIVE_JOB and j['conclusion'] == 'success']
                    if len(native) != 1 or not NATIVE_STEPS.issubset({s['name'] for s in native[0].get('steps', []) if s['conclusion'] == 'success'}):
                        row['reason'] = 'Actual native UI acceptance job missing'
                        rows[key] = row
                        continue
                    commit = api.api(f'repos/{api.repo}/git/commits/{run["head_sha"]}')
                    tree = api.api(f'repos/{api.repo}/git/trees/{commit["tree"]["sha"]}?recursive=1')
                    if tree.get('truncated'):
                        raise ValueError('Source tree is truncated')
                    source_identity = {}
                    for field, prefixes in [('shellTreeSha256', ('shell/',)), ('transportTreeSha256', ('app/', 'tests/e2e/qga.py'))]:
                        files = sorted((e['path'], e['sha']) for e in tree['tree'] if e['type'] == 'blob' and e['path'].startswith(prefixes))
                        if not files:
                            raise ValueError('Source identity scope empty')
                        source_identity[field] = digest(json.dumps(files, separators=(',', ':')).encode())
                    artifacts = api.pages(f'repos/{api.repo}/actions/runs/{run["id"]}/artifacts', 'artifacts')
                    matches = [a for a in artifacts if a['name'] == f'native-gui-soak-proof-{run["id"]}-{attempt}']
                    if len(matches) == 1:
                        try:
                            if matches[0].get('size_in_bytes', MAX_PROOF + 1) > MAX_PROOF:
                                raise ValueError('Native proof download too large')
                            verified = verify_proof(api.api(f'repos/{api.repo}/actions/artifacts/{matches[0]["id"]}/zip', True), run, matches[0])
                            if any(verified[field] != value for field, value in source_identity.items()):
                                raise ValueError('Proof shell/transport does not match source tree')
                            products = [a for a in artifacts if a['name'] == f'native-shell-build-{run["id"]}-{attempt}']
                            if len(products) != 1 or products[0].get('size_in_bytes', MAX_PRODUCT + 1) > MAX_PRODUCT:
                                raise ValueError('Bound packaged native shell artifact missing or oversized')
                            verified.update(verify_product(api.api(f'repos/{api.repo}/actions/artifacts/{products[0]["id"]}/zip', True), run, products[0], verified))
                            row.update(verified)
                            row.update(eligible=True, reason='')
                        except (ValueError, KeyError, TypeError, OverflowError, zipfile.BadZipFile, json.JSONDecodeError) as error:
                            row['reason'] = str(error)
                rows[key] = row
    # Diagnoses can arrive after the discovery window; refresh every retained red.
    for key, row in rows.items():
        diagnosis = config.get('diagnoses', {}).get(f'{key[0]}:{key[1]}')
        row.pop('diagnosisIssue', None)
        if diagnosis and row['verdict'] != 'success':
            issue = api.issue(diagnosis)
            if has_run_link(issue.get('body'), row['runUrl']):
                row['diagnosisIssue'] = diagnosis
    # Release identity is informational and never supplies proof by itself.
    releases = api.pages(f'repos/{api.repo}/releases', None)
    for row in rows.values():
        matches = [release for release in releases if release['tag_name'].startswith('auto-v') and
                   has_run_link(release.get('body'), row['runUrl'])]
        if len(matches) == 1:
            row['autoReleaseTag'] = matches[0]['tag_name']
    return sorted(rows.values(), key=lambda r: (r['date'], r.get('startedAt', ''), r['runId'], r['runAttempt'])), issues


def render(rows, summary):
    lines = ['# Native GUI soak ledger', '',
             f'Current eligible streak: **{summary["streak"]} days**. Valid: **{str(summary["valid"]).lower()}**.', '',
             summary.get('reason', '') or f'Counted through {summary["throughDate"]}.', '',
             'Only completed UTC days count. Every scheduled attempt is retained. Wails, missing proof, and branch runs do not qualify.', '',
             '| UTC date | Source / attempt | Verdict | Native artifact | Auto release | Diagnosis / exclusion |',
             '|---|---|---|---|---|---|']
    for row in reversed(rows):
        detail = f'#{row["diagnosisIssue"]}' if row.get('diagnosisIssue') else row.get('reason', '')
        detail = detail.replace('|', '\\|').replace('\n', ' ')
        artifact_label = row.get('shell', 'unproven') + ' / ' + row.get('artifactSha256', '—')
        lines.append(f'| {row["date"]} | [{row["sourceSha"][:12]} / {row["runId"]}:{row["runAttempt"]}]({row["runUrl"]}) | {row["verdict"]} | {artifact_label} | {row.get("autoReleaseTag") or "—"} | {detail} |')
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    old = json.loads(args.state.read_text()) if args.state.exists() else []
    today = dt.datetime.now(dt.timezone.utc).date()
    rows, issues = collect(GitHub(args.repo), old, config, today)
    summary = summarize(rows, config, issues, today)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'attempts.json').write_text(json.dumps(rows, indent=2) + '\n')
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    authority = {str(number): {'state': issue.get('state'), 'closedAt': issue.get('closed_at'),
                              'bodySha256': digest((issue.get('body') or '').encode()),
                              'url': issue.get('html_url')} for number, issue in issues.items()}
    (args.output / 'prerequisites.json').write_text(json.dumps(authority, indent=2) + '\n')
    (args.output / 'soak.md').write_text(render(rows, summary))


if __name__ == '__main__':
    main()
