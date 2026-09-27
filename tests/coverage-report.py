#!/usr/bin/env python3
"""Validate measured Go profiles, retain totals, and enforce the project gate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BLOCK = re.compile(r'(.+):(\d+)\.(\d+),(\d+)\.(\d+) (\d+) (\d+)')


def read_profile(path, module):
    lines = path.read_text(encoding='utf-8').splitlines()
    if not lines or lines[0] != 'mode: atomic':
        raise ValueError(f'{path.name}: missing atomic coverage header')
    blocks = []
    seen = set()
    for line in lines[1:]:
        match = BLOCK.fullmatch(line)
        if not match:
            raise ValueError(f'{path.name}: malformed coverage block')
        source, start, column, end, end_column, statements, count = match.groups()
        start, column, end, end_column, statements, count = map(int,
            (start, column, end, end_column, statements, count))
        prefix = module['module'] + '/'
        if not source.startswith(prefix):
            raise ValueError(f'{path.name}: unexpected source module {source}')
        relative = source[len(prefix):]
        parts = relative.split('/')
        if any(part in ('', '.', '..') for part in parts) or '\\' in relative:
            raise ValueError(f'{path.name}: invalid source path')
        if start < 1 or column < 1 or end < start or end_column < 1:
            raise ValueError(f'{path.name}: invalid coverage coordinates or statement count')
        if end == start and end_column < column:
            raise ValueError(f'{path.name}: reversed coverage block')
        key = (source, start, column, end, end_column)
        if key in seen:
            raise ValueError(f'{path.name}: duplicate coverage block')
        seen.add(key)
        blocks.append({'path': module['directory'] + '/' + relative, 'start': start,
            'end': end - int(end_column == 1 and end > start), 'statements': statements, 'covered': count > 0})
    if not any(block['statements'] for block in blocks):
        raise ValueError(f'{path.name}: no measured statements')
    return blocks


def patch_lines(base):
    if not base:
        return None
    diff = subprocess.run(['git', 'diff', '--unified=0', '--no-renames', base, 'HEAD', '--',
        '*.go'], cwd=ROOT, text=True, capture_output=True, check=True).stdout
    paths = {}
    path = None
    for line in diff.splitlines():
        if line.startswith('+++ b/'):
            path = line[6:]
        elif line.startswith('+++ '):
            path = None
        elif path and line.startswith('@@ '):
            match = re.match(r'@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@', line)
            if not match:
                raise ValueError('cannot parse changed Go line range')
            start = int(match[1])
            size = int(match[2] or 1)
            paths.setdefault(path, set()).update(range(start, start + size))
    return paths


def generate(directory, config, base=None):
    if config['version'] != 1 or not config['modules']:
        raise ValueError('unsupported or empty coverage configuration')
    for field in ('name', 'directory', 'module'):
        values = [module[field] for module in config['modules']]
        if len(values) != len(set(values)):
            raise ValueError(f'duplicate configured coverage {field}')
    expected = {module['name'] + '.out' for module in config['modules']}
    if {path.name for path in directory.glob('*.out')} != expected:
        raise ValueError('missing or unconfigured module profile')
    measured = []
    all_blocks = []
    for module in config['modules']:
        blocks = read_profile(directory / (module['name'] + '.out'), module)
        total = sum(block['statements'] for block in blocks)
        covered = sum(block['statements'] for block in blocks if block['covered'])
        measured.append({'name': module['name'], 'statements': total, 'covered': covered,
            'percent': 100 * covered / total, 'profileSha256': hashlib.sha256(
                (directory / (module['name'] + '.out')).read_bytes()).hexdigest()})
        all_blocks.extend(blocks)
    total = sum(item['statements'] for item in measured)
    covered = sum(item['covered'] for item in measured)
    threshold = config['minimumStatementPercent']
    if isinstance(threshold, bool) or not isinstance(threshold, (int, float)) or not 0 <= threshold <= 100:
        raise ValueError('invalid project coverage threshold')
    patch = None
    changed = patch_lines(base)
    if changed is not None:
        observations = {}
        for block in all_blocks:
            if not block['statements']:
                continue
            for line in changed.get(block['path'], set()):
                if block['start'] <= line <= block['end']:
                    key = (block['path'], line)
                    observations[key] = observations.get(key, True) and block['covered']
        hits = sum(observations.values())
        patch = {'base': base, 'instrumentedChangedLines': len(observations), 'covered': hits,
            'percent': 100 * hits / len(observations) if observations else None,
            'informationalTargetPercent': config['patchTargetPercent'],
            'method': 'A changed instrumented line counts only if every block on it was hit.'}
    passed = covered * 100 >= threshold * total
    return {'schemaVersion': 1, 'sourceSha': subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'os': sys.platform, 'scope': 'Go statements compiled by the current OS in all configured fast-tier modules',
        'modules': measured, 'statements': total, 'covered': covered,
        'percent': 100 * covered / total, 'minimumStatementPercent': threshold,
        'thresholdPassed': passed, 'patch': patch}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--config', type=Path, default=ROOT / '.coverage-thresholds.json')
    parser.add_argument('--base', default=os.environ.get('WOOTC_COVERAGE_BASE_SHA'))
    args = parser.parse_args()
    for name in ('summary.json', 'summary.md'):
        (args.directory / name).unlink(missing_ok=True)
    config = json.loads(args.config.read_text(encoding='utf-8'))
    report = generate(args.directory, config, args.base)
    (args.directory / 'summary.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    rows = ['## Measured Go coverage', '', '| Module | Covered statements | Total | Percent |',
        '|---|---:|---:|---:|']
    rows += [f"| {item['name']} | {item['covered']} | {item['statements']} | {item['percent']:.2f}% |"
        for item in report['modules']]
    rows += ['', f"Project: {report['percent']:.2f}% (minimum {report['minimumStatementPercent']}%).",
        '', report['scope'] + '. Windows-only code is not measured by a Linux run.',
        'A passing report does not mean every subprocess was instrumented.']
    if report['patch'] and report['patch']['percent'] is not None:
        patch = report['patch']
        rows += ['', f"Changed instrumented lines: {patch['percent']:.2f}% "
            f"(informational target {patch['informationalTargetPercent']}%).", patch['method']]
    else:
        rows += ['', 'Changed-line coverage: unavailable or no changed instrumented lines.']
    summary = '\n'.join(rows) + '\n'
    (args.directory / 'summary.md').write_text(summary, encoding='utf-8')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as stream:
            stream.write(summary)
    print(summary)
    return 0 if report['thresholdPassed'] else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f'Coverage gate failed: {error}')
