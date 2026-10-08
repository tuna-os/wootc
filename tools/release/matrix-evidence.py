#!/usr/bin/env python3
"""Grade the full-tier E2E matrix evidence for one release SHA (#240, v1.0 criterion 3).

The release notes cite one run set: the full-tier `e2e-matrix.yml` dispatches at
the RC SHA, in script mode and in GUI mode, plus any retries. A green it inherits
from an earlier commit does not count. This tool grades that run set against
`tests/e2e/matrix.tsv` *as it is at that SHA* and prints the evidence record.

    tools/release/matrix-evidence.py check --sha <rc-sha> --run <id> [--run <id> ...]
    tools/release/matrix-evidence.py grade snapshot.json --matrix matrix.tsv

`check` reads GitHub (gh api) and writes the snapshot it graded (`--snapshot`),
so the record can be re-graded offline. `grade` is the pure half.

A cell is green only on observables, never on a proxy:
  * its final attempt's job concluded `success`;
  * that job's log prints the run-e2e.sh pass banner, which is reached only
    after the failure ledger is empty (run-e2e.sh "Done" block), and does not
    print the "failure(s) were recorded" ledger dump;
  * every earlier red attempt carries the harness's own flake notice (written
    only for a known infra signature, see note_flake). Any other red is an
    unexplained red and fails the record, even if a retry went green.
Exit 0 only when every expected cell is green in both modes and the matrix has
the BitLocker (bitlocker=on) and offline (offline=on) cells.
"""
import argparse
import json
import os
import re
import subprocess
import sys

WORKFLOW = '.github/workflows/e2e-matrix.yml'
# The run-name e2e-matrix.yml sets, so the tier and mode of a dispatch are
# read from the run itself and not guessed from its jobs.
TITLE = re.compile(r'^E2E matrix \((smoke|full), (script|gui)(?:, grep=(.*))?\)$')
PASS_BANNER = 'wootc E2E test: ALL TESTS PASSED'
# Cells that end before the full cycle print their own positive marker and
# exit 0 without the banner: the fault-injection recovery cells and the
# Secure Boot refusal cell (firmware_db=none, #322). Each cell is graded on
# the marker its scenario prints (run-e2e.sh), not on the banner alone.
PASS_MARKERS = {
    'banner': PASS_BANNER,
    'recovery': 'All recovery checks PASSED for fault-injection',
    'sb-refusal': 'Secure Boot refusal cell PASSED',
}
LEDGER_DUMP = 'failure(s) were recorded during this run'
FLAKE_NOTICE = re.compile(r'run-e2e\.sh classified this failure as a flake: ([a-z-]+)')
MODES = ('script', 'gui')


def parse_matrix(text, include_phase3=False):
    """Mirror the e2e-matrix.yml plan step for tier=full.

    Returns (cells, skipped). Each cell carries the axes the workflow keys on.
    """
    cells, skipped = [], []
    for line in text.splitlines():
        if not line or line.startswith('#'):
            continue
        f = line.split('\t')
        if len(f) < 6:
            continue
        opts = [o for o in (f[6] if len(f) > 6 else '').split(',') if o]
        cell = {
            'name': f[1],
            'image': f[2],
            'bitlocker': 'bitlocker=on' in opts,
            'offline': 'offline=on' in opts,
            'filesystem': next((o.split('=', 1)[1] for o in opts if o.startswith('filesystem=')), ''),
            'fault': next((o.split('=', 1)[1] for o in opts if o.startswith('fault=')), ''),
            'firmware_db': next((o.split('=', 1)[1] for o in opts if o.startswith('firmware_db=')), ''),
        }
        # phase3 cells overflow hosted runner disks; the workflow drops them
        # unless INCLUDE_PHASE3=1, so the hosted record cannot hold them.
        if 'phase3=on' in opts and not include_phase3:
            skipped.append(cell['name'])
            continue
        cells.append(cell)
    return cells, skipped


def gui_applies(cell):
    """The gui_install guard in e2e-matrix.yml: GUI mode drives only these cells."""
    return not cell['bitlocker'] and not cell['filesystem'] and not cell['offline']


def pass_marker(cell):
    """The PASS_MARKERS key a green job of this cell must show in its log."""
    if cell.get('fault'):
        return 'recovery'
    if cell.get('firmware_db') == 'none':
        return 'sb-refusal'
    return 'banner'


def markers_of(job):
    """Markers a collected job showed; older snapshots only recorded passBanner."""
    if 'passMarkers' in job:
        return set(job['passMarkers'])
    return {'banner'} if job.get('passBanner') else set()


def expected(cells):
    return {
        'script': [c['name'] for c in cells],
        'gui': [c['name'] for c in cells if gui_applies(c)],
    }


def run_mode(run):
    m = TITLE.match(run.get('display_title', ''))
    if not m:
        return None, None, None
    return m.group(1), m.group(2), m.group(3) or ''


def grade(snapshot, matrix_text, include_phase3=False):
    """Return (ok, problems, rows, cells, skipped)."""
    sha = snapshot['sha']
    problems = []
    cells, skipped = parse_matrix(matrix_text, include_phase3)
    if not any(c['bitlocker'] for c in cells):
        problems.append('matrix has no bitlocker=on cell (M3.2)')
    if not any(c['offline'] for c in cells):
        problems.append('matrix has no offline=on cell (M2.3)')

    attempts = {m: {} for m in MODES}
    primary = {m: [] for m in MODES}
    for run in snapshot['runs']:
        rid = run['id']
        if run.get('path') != WORKFLOW:
            problems.append(f'run {rid} is {run.get("path")}, not {WORKFLOW}')
            continue
        if run.get('head_sha') != sha:
            problems.append(f'run {rid} is at {run.get("head_sha", "")[:12]}, not the RC SHA {sha[:12]}')
            continue
        tier, mode, grep = run_mode(run)
        if tier is None:
            problems.append(f'run {rid} title {run.get("display_title")!r} does not name its tier and mode')
            continue
        if tier != 'full':
            problems.append(f'run {rid} is tier={tier}, not tier=full')
            continue
        if not grep:
            primary[mode].append(rid)
        for job in run.get('jobs', []):
            name = job['name']
            if name == 'plan':
                continue
            if job.get('head_sha', sha) != sha:
                problems.append(f'job {job["id"]} in run {rid} is not at the RC SHA')
                continue
            cell = name.split(' / ')[0]
            attempts[mode].setdefault(cell, []).append(dict(job, run_id=rid, created_at=run.get('created_at', '')))

    for mode in MODES:
        if not primary[mode]:
            problems.append(f'no unfiltered tier=full {mode}-mode run at the RC SHA')

    rows = []
    want = expected(cells)
    by_name = {c['name']: c for c in cells}
    for mode in MODES:
        for cell in want[mode]:
            history = sorted(attempts[mode].get(cell, []),
                             key=lambda j: (j['created_at'], j['run_id'], j.get('run_attempt', 1)))
            if not history:
                problems.append(f'{mode}: {cell} has no job in the run set')
                rows.append({'mode': mode, 'cell': cell, 'final': None, 'retries': []})
                continue
            final, earlier = history[-1], history[:-1]
            retries = []
            for job in earlier:
                if job.get('conclusion') == 'success':
                    continue
                flake = job.get('flake', '')
                retries.append({'run_id': job['run_id'], 'attempt': job.get('run_attempt', 1),
                                'conclusion': job.get('conclusion'), 'flake': flake})
                if not flake:
                    problems.append(f'{mode}: {cell} red in run {job["run_id"]} attempt '
                                    f'{job.get("run_attempt", 1)} with no infra flake verdict (unexplained red)')
            if final.get('conclusion') != 'success':
                problems.append(f'{mode}: {cell} final attempt is {final.get("conclusion")} '
                                f'(run {final["run_id"]})')
            elif pass_marker(by_name[cell]) not in markers_of(final):
                problems.append(f'{mode}: {cell} job succeeded but its log has no '
                                f'{PASS_MARKERS[pass_marker(by_name[cell])]!r} marker '
                                f'(run {final["run_id"]})')
            elif final.get('ledgerDump'):
                problems.append(f'{mode}: {cell} log dumps a non-empty failure ledger (run {final["run_id"]})')
            rows.append({'mode': mode, 'cell': cell, 'final': final, 'retries': retries})
    return not problems, problems, rows, cells, skipped


def render(snapshot, ok, problems, rows, cells, skipped):
    repo = snapshot.get('repo', 'tuna-os/wootc')
    base = f'https://github.com/{repo}/actions/runs'
    out = [f'### Full-tier matrix evidence at `{snapshot["sha"]}`', '',
           f'**Verdict:** {"GREEN" if ok else "NOT GREEN"}', '', 'Runs:']
    for run in snapshot['runs']:
        out.append(f'- [{run["id"]}]({base}/{run["id"]}) {run.get("display_title", "")}')
    axes = [c['name'] for c in cells if c['bitlocker'] or c['offline']]
    out += ['', f'BitLocker and offline cells: {", ".join(axes) or "none"}.']
    if skipped:
        out.append(f'Not on the hosted matrix (phase3, disk size): {", ".join(skipped)}.')
    out += ['', '| Mode | Cell | Final run | Ledger | Infra retries |', '|---|---|---|---|---|']
    for r in rows:
        f = r['final']
        if f is None:
            final, ledger = 'missing', '-'
        else:
            final = f'[{f["run_id"]}#{f.get("run_attempt", 1)}]({base}/{f["run_id"]}/job/{f["id"]}) {f.get("conclusion")}'
            ledger = 'empty' if markers_of(f) and not f.get('ledgerDump') else 'not proven'
        retry = ', '.join(f'{x["run_id"]}#{x["attempt"]} {x["flake"] or "UNEXPLAINED"}' for x in r['retries']) or '-'
        out.append(f'| {r["mode"]} | {r["cell"]} | {final} | {ledger} | {retry} |')
    if problems:
        out += ['', 'Problems:'] + [f'- {p}' for p in problems]
    return '\n'.join(out) + '\n'


def gh_json(path):
    return json.loads(subprocess.run(['gh', 'api', path], check=True, capture_output=True, text=True).stdout)


def gh_text(path):
    return subprocess.run(['gh', 'api', '--allow-escape-sequences', path],
                          check=True, capture_output=True, text=True, errors='replace').stdout


def collect(repo, sha, run_ids):
    """Read the run set from GitHub into a self-contained snapshot."""
    runs = []
    for rid in run_ids:
        run = gh_json(f'repos/{repo}/actions/runs/{rid}')
        jobs, page = [], 1
        while True:
            batch = gh_json(f'repos/{repo}/actions/runs/{rid}/jobs?filter=all&per_page=100&page={page}')['jobs']
            jobs += batch
            if len(batch) < 100:
                break
            page += 1
        kept = []
        for job in jobs:
            entry = {k: job.get(k) for k in ('id', 'name', 'conclusion', 'run_attempt', 'head_sha')}
            if job['name'] != 'plan':
                if job.get('conclusion') == 'success':
                    log = gh_text(f'repos/{repo}/actions/jobs/{job["id"]}/logs')
                    entry['passMarkers'] = sorted(k for k, m in PASS_MARKERS.items() if m in log)
                    entry['passBanner'] = PASS_BANNER in log
                    entry['ledgerDump'] = LEDGER_DUMP in log
                else:
                    notes = gh_json(f'repos/{repo}/check-runs/{job["id"]}/annotations')
                    hit = next((m.group(1) for n in notes
                                for m in [FLAKE_NOTICE.search(n.get('message', ''))] if m), '')
                    entry['flake'] = hit
            kept.append(entry)
        runs.append({k: run.get(k) for k in ('id', 'path', 'head_sha', 'display_title', 'created_at')}
                    | {'jobs': kept})
    return {'schemaVersion': 1, 'repo': repo, 'sha': sha, 'runs': runs}


def matrix_at(sha):
    return subprocess.run(['git', 'show', f'{sha}:tests/e2e/matrix.tsv'],
                          check=True, capture_output=True, text=True).stdout


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('check', help='collect from GitHub, then grade')
    c.add_argument('--sha', required=True)
    c.add_argument('--run', action='append', required=True, type=int)
    c.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY', 'tuna-os/wootc'))
    c.add_argument('--snapshot', help='write the collected snapshot here')
    g = sub.add_parser('grade', help='grade a saved snapshot')
    g.add_argument('snapshot')
    g.add_argument('--matrix', help='matrix.tsv (default: git show <sha>:tests/e2e/matrix.tsv)')
    for s in (c, g):
        s.add_argument('--include-phase3', action='store_true')
    a = p.parse_args(argv)

    if a.cmd == 'check':
        sha = subprocess.run(['git', 'rev-parse', a.sha], check=True, capture_output=True,
                             text=True).stdout.strip()
        snap = collect(a.repo, sha, a.run)
        if a.snapshot:
            with open(a.snapshot, 'w', encoding='utf-8') as fh:
                json.dump(snap, fh, indent=1)
        matrix = matrix_at(sha)
    else:
        with open(a.snapshot, encoding='utf-8') as fh:
            snap = json.load(fh)
        if a.matrix:
            with open(a.matrix, encoding='utf-8') as fh:
                matrix = fh.read()
        else:
            matrix = matrix_at(snap['sha'])
    ok, problems, rows, cells, skipped = grade(snap, matrix, a.include_phase3)
    sys.stdout.write(render(snap, ok, problems, rows, cells, skipped))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
