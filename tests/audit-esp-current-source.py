"""Compact audit of combined source, preserved checkpoints and native proof inputs."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('worktree', type=Path)
for name in ('classic_assets', 'versioned_assets', 'esp_assets', 'closure'):
    parser.add_argument('--'+name.replace('_', '-'), type=Path, required=True)
args = parser.parse_args()
proof = args.worktree/'docs/experiments/evidence/2026-09-27-esp-current-source'
record = json.loads((proof/'provenance.json').read_text())


def check(base, entries):
    for path, expected in entries.items():
        if hashlib.sha256((base/path).read_bytes()).hexdigest() != expected:
            raise SystemExit('hash differs: '+str(base/path))
    return len(entries)


counts = {'sources': check(args.worktree, record['sourceHashes']),
          'results': check(proof, record['resultHashes']),
          'checkpoints': check(args.worktree, record['checkpointReceiptHashes'])}
for name, path in record['assetReceipts'].items():
    checkpoint = json.loads((args.worktree/path).read_text())
    counts[name] = check(getattr(args, name), checkpoint['assetHashes'])
    if 'verifierClosureHashes' in checkpoint:
        counts['verifierClosure'] = check(args.closure, checkpoint['verifierClosureHashes'])
print(json.dumps({'hashesMatch': True, 'counts': counts,
                  'worktreeClean': not subprocess.check_output(['git', 'status', '--porcelain'], cwd=args.worktree, text=True).strip(),
                  'providersImplemented': record['providersImplemented'],
                  'firmwareAcceptance': False, 'classicOsBootAcceptance': False}, sort_keys=True))
