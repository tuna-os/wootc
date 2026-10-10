#!/usr/bin/env python3
"""Check the source checkpoint; this does not execute a VM or image producer."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
record = json.loads((root/'docs/experiments/evidence/2026-09-27-esp-orchestrator/provenance.json').read_text())
for name, expected in record['sourceHashes'].items():
    if hashlib.sha256((root/name).read_bytes()).hexdigest() != expected:
        raise SystemExit('source differs: '+name)
if any(record.get(gate, False) for gate in ('firmwareAcceptance', 'classicOsBootAcceptance', 'producerExecuted', 'launcherExecuted', 'windowsHelpersExecuted', 'firmwareStoreBindingVerified')):
    raise SystemExit('checkpoint claims an unexecuted gate')
print(json.dumps({'sourcesMatch': len(record['sourceHashes']), 'nativeTests': record['nativeTests'],
                  'producerExecuted': False, 'launcherExecuted': False, 'firmwareStoreBindingVerified': False, 'firmwareAcceptance': False, 'classicOsBootAcceptance': False}, sort_keys=True))
