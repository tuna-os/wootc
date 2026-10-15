#!/usr/bin/env python3
"""Append-only run result authority; observations never imply terminal success."""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

REQUIRED = {
    'snapshot-prime': {'snapshot-windows-identity', 'snapshot-compressed', 'snapshot-key'},
    'full-cycle': {'deployed', 'linux-root', 'linux-proof', 'user-data', 'windows-return', 'healthy'},
    'native-cycle': {'deployed', 'linux-root', 'linux-proof', 'user-data', 'native-boot', 'native-user-data'},
    'recovery': {'recovery-interrupted', 'recovery-retry', 'recovery-uninstall', 'recovery-windows'},
    # Firmware that trusts no third-party CA (#322): the pass is a refusal in
    # words AND proof that nothing was written, never a completed install.
    'secure-boot-refusal': {'secure-boot-refused', 'secure-boot-untouched'},
}
OPTIONAL = {'gui-install'}
DOMAINS = {'runner', 'infrastructure', 'product'}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def regular(fd):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError('Result authority must be an independent regular file')


def load(stream, run):
    stream.seek(0)
    lines = stream.readlines()
    if not lines or not lines[-1].endswith('\n'):
        raise ValueError('Missing or torn result evidence')
    rows = [json.loads(line) for line in lines]
    if rows[0].get('kind') != 'started' or rows[0].get('scenario') not in REQUIRED:
        raise ValueError('Run initialization is missing')
    required = rows[0].get('requiredAssertions', [])
    if not isinstance(required, list) or not REQUIRED[rows[0]['scenario']].issubset(required) or not set(required).issubset(REQUIRED[rows[0]['scenario']] | OPTIONAL):
        raise ValueError('Required scenario assertions were removed or changed')
    for number, row in enumerate(rows):
        if row.get('runId') != run or row.get('sequence') != number or row.get('schemaVersion') != 1:
            raise ValueError('Foreign run or discontinuous result evidence')
        if number and row.get('kind') not in {'assertion', 'failure', 'terminal'}:
            raise ValueError('Invalid result kind')
        if row.get('kind') in {'assertion', 'failure'} and row.get('domain') not in DOMAINS:
            raise ValueError('Invalid result domain')
        if row.get('kind') == 'assertion' and (row.get('status') != 'passed' or not row.get('assertionId')):
            raise ValueError('Invalid assertion observation')
        if row.get('kind') == 'terminal':
            if number != len(rows) - 1:
                raise ValueError('Result mutation after terminal verdict')
            if row.get('verdict') not in {'passed', 'failed', 'inconclusive'} or row.get('productVerdict') not in {'passed', 'failed', 'unknown'} or not isinstance(row.get('exitCode'), int):
                raise ValueError('Malformed terminal verdict')
    return rows


def append(stream, rows, run, record):
    row = {'schemaVersion': 1, 'sequence': len(rows), 'runId': run, 'observedAt': now(), **record}
    stream.seek(0, os.SEEK_END)
    stream.write(json.dumps(row, ensure_ascii=True) + '\n')
    stream.flush()
    os.fsync(stream.fileno())
    return row


def init(path, run, scenario, extras):
    if not run or scenario not in REQUIRED:
        raise ValueError('Explicit run identity and scenario required')
    required = set(filter(None, extras.split(',')))
    if not required.issubset(OPTIONAL):
        raise ValueError('Unknown optional assertion contract')
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'r+', encoding='utf-8') as stream:
        regular(stream.fileno())
        append(stream, [], run, {'kind': 'started', 'scenario': scenario, 'requiredAssertions': sorted(REQUIRED[scenario] | required)})


def operate(args):
    fd = os.open(args.path, os.O_RDWR | os.O_NOFOLLOW)
    with os.fdopen(fd, 'r+', encoding='utf-8') as stream:
        regular(stream.fileno())
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
        rows = load(stream, args.run)
        if rows[-1]['kind'] == 'terminal':
            if args.operation == 'abort':
                return 0 if args.code != 0 or rows[-1]['verdict'] == 'passed' else 1
            raise ValueError('Terminal result already committed')
        if args.operation == 'record':
            if args.domain not in DOMAINS or args.kind not in {'failure', 'assertion'}:
                raise ValueError('Invalid typed observation')
            if args.kind == 'assertion' and not args.assertion:
                raise ValueError('Assertion identity required')
            if args.phase:
                catalogue = Path(__file__).resolve().parents[3] / 'payload/steps.tsv'
                known = {line.split('\t')[0] for line in catalogue.read_text().splitlines() if line and not line.startswith('#')}
                if args.phase not in known:
                    raise ValueError('Unknown catalogue phase')
            append(stream, rows, args.run, {'kind': args.kind, 'domain': args.domain,
                   'assertionId': args.assertion, 'status': 'passed' if args.kind == 'assertion' else 'failed',
                   'phaseId': args.phase if args.domain == 'product' else '', 'message': args.message})
            return 0
        failures = [r for r in rows if r['kind'] == 'failure']
        observation_domain = 'infrastructure' if rows[0]['scenario'] == 'snapshot-prime' else 'product'
        observed = {r['assertionId'] for r in rows if r['kind'] == 'assertion' and r['domain'] == observation_domain}
        missing = sorted(set(rows[0]['requiredAssertions']) - observed)
        # Human ledger remains an additional failure signal, never empty-file proof.
        human_failed = False
        if args.operation == 'finish':
            legacy_fd = os.open(args.legacy, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(legacy_fd, 'r', encoding='utf-8') as legacy:
                regular(legacy.fileno())
                human_failed = bool(legacy.read())
        passed = args.operation == 'finish' and not failures and not missing and not human_failed
        product_failed = any(r['domain'] == 'product' for r in failures)
        if args.marker and rows[0]['scenario'] == 'snapshot-prime':
            raise ValueError('Snapshot preparation cannot publish a product GUI marker')
        if passed and args.marker and os.path.lexists(args.marker):
            raise ValueError('Refusing an existing publish marker')
        terminal = append(stream, rows, args.run, {'kind': 'terminal',
            'verdict': 'passed' if passed else ('failed' if product_failed else 'inconclusive'),
            'productVerdict': 'passed' if passed and observation_domain == 'product' else ('failed' if product_failed else 'unknown'),
            'failureCount': len(failures), 'missingAssertions': missing,
            'humanFailureRecorded': human_failed, 'exitCode': 0 if passed else max(args.code, 1)})
        if passed and args.marker:
            marker = Path(args.marker)
            marker.parent.mkdir(parents=True, exist_ok=True)
            # The marker is committed only AFTER the fsynced terminal record.
            fd, temporary = tempfile.mkstemp(prefix='.passed.', dir=marker.parent)
            try:
                with os.fdopen(fd, 'w') as output:
                    output.write(f'{args.run} image={args.image}\n')
                    output.flush()
                    os.fsync(output.fileno())
                os.link(temporary, marker)
                directory = os.open(marker.parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        print(json.dumps(terminal))
        return 0 if passed or (args.operation == 'abort' and args.code != 0) else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['init', 'record', 'finish', 'abort'])
    parser.add_argument('path')
    parser.add_argument('run')
    parser.add_argument('--scenario', default='full-cycle')
    parser.add_argument('--required', default='')
    parser.add_argument('--kind', default='failure')
    parser.add_argument('--domain', default='runner')
    parser.add_argument('--assertion', default='')
    parser.add_argument('--phase', default='')
    parser.add_argument('--message', default='')
    parser.add_argument('--legacy', default='')
    parser.add_argument('--marker', default='')
    parser.add_argument('--image', default='')
    parser.add_argument('--code', type=int, default=1)
    args = parser.parse_args()
    try:
        if args.operation == 'init':
            init(args.path, args.run, args.scenario, args.required)
            return 0
        return operate(args)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'[FAIL] Result evidence rejected: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
