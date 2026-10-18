#!/usr/bin/env python3
"""Read a pinned public store; compare its variables to pinned upstream tooling."""
import argparse
import hashlib
import json
from pathlib import Path
import runpy
import sys
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('store', type=Path); parser.add_argument('store_sha256')
parser.add_argument('wheel', type=Path); parser.add_argument('upstream_source', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
launcher = runpy.run_path(str(root/'tests/e2e/esp-chain/launch.py'))
digest = launcher['digest']
expected_wheel = 'dd4cc56e5278ad9c151ec8f73b897bab55c055befe0502aeec7526b27c18097e'
if digest(args.store) != args.store_sha256 or digest(args.wheel) != expected_wheel:
    parser.exit(1, 'probe input differs from pin\n')
with zipfile.ZipFile(args.wheel) as archive:
    for name in archive.namelist():
        if name.startswith('virt/') and name.endswith('.py'):
            actual = (args.upstream_source/name).read_bytes()
            if hashlib.sha256(actual).digest() != hashlib.sha256(archive.read(name)).digest():
                parser.exit(1, 'upstream parser source changed\n')
sys.path.insert(0, str(args.upstream_source))
from virt.firmware.varstore.edk2 import Edk2VarStore
actual = launcher['variables'](args.store)
upstream = {str(v.name)+'-'+str(v.guid): int(v.attr).to_bytes(4, 'little')+bytes(v.data)
            for v in Edk2VarStore(str(args.store)).get_varlist().values()}
if actual != upstream or digest(args.store) != args.store_sha256:
    parser.exit(1, 'variable parsers differ or input changed\n')
print(json.dumps({'storeSha256': args.store_sha256, 'upstreamWheelSha256': expected_wheel,
                  'allActiveVariablesMatchUpstream': len(actual),
                  'dbSha256': hashlib.sha256(actual['db-'+launcher['DB_GUID']]).hexdigest(),
                  'dbxSha256': hashlib.sha256(actual['dbx-'+launcher['DB_GUID']]).hexdigest(),
                  'firmwareAcceptance': False, 'classicOsBootAcceptance': False}, sort_keys=True))
