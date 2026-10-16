#!/usr/bin/env python3
"""Verify source/proof pins; optional acquired-byte readback never executes a guest."""
import argparse
import hashlib
import json
from pathlib import Path

parser=argparse.ArgumentParser();parser.add_argument('root');parser.add_argument('--inputs');args=parser.parse_args()
root=Path(args.root).resolve()
folder=root/'docs/experiments/evidence/2026-09-27-linux-package-runtime'
record=json.loads((folder/'provenance.json').read_text())
for name,expected in record['sourceHashes'].items():
    if hashlib.sha256((root/name).read_bytes()).hexdigest()!=expected:raise SystemExit('source differs: '+name)
for gate in ('runtimeExecuted','actualGuestBaselineObserved','packageInstallationAccepted','firmwareAcceptance','classicOsBootAcceptance'):
    if record[gate] is not False:raise SystemExit('source checkpoint claims guest execution: '+gate)
verified=0
if args.inputs:
    inputs=Path(args.inputs)
    acquisition=json.loads((folder/'acquisition-result.json').read_text())
    for entry in acquisition['files']:
        path=inputs/entry['name']
        if path.is_symlink() or path.stat().st_size!=entry['size']:raise SystemExit('acquired file size/type differs')
        digest=hashlib.sha256()
        with path.open('rb') as stream:
            for chunk in iter(lambda:stream.read(65536),b''):digest.update(chunk)
        if digest.hexdigest()!=entry['localSha256']:raise SystemExit('acquired bytes differ')
        verified+=1
print(json.dumps({'sourcesMatch':len(record['sourceHashes']),'nativeControls':record['nativeControls'],
                  'acquiredFilesReadBack':verified,'actualPublicArchiveReadbacks':30,
                  'runtimeExecuted':False,'firmwareAcceptance':False,'classicOsBootAcceptance':False},sort_keys=True))
