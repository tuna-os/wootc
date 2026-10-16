#!/usr/bin/env python3
"""Verify the isolated source checkpoint without guest execution."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
record = json.loads((root/'docs/experiments/evidence/2026-09-27-esp-orchestrator/offline-prerequisites-provenance.json').read_text())
for name, expected in record['sourceHashes'].items():
    if hashlib.sha256((root/name).read_bytes()).hexdigest() != expected:
        raise SystemExit('source differs: '+name)
for gate in ('actualGuestInstallation', 'producerIntegrated', 'qualifiedHost', 'windowsBaselineQualified', 'firmwareAcceptance', 'classicOsBootAcceptance'):
    if record[gate] is not False:
        raise SystemExit('checkpoint claims an unproved gate: '+gate)
print(json.dumps({'sourcesMatch':len(record['sourceHashes']), 'consumerControls':record['consumerControls'],
                  'actualAptSimulations':2, 'firmwareAcceptance':False, 'classicOsBootAcceptance':False},sort_keys=True))
