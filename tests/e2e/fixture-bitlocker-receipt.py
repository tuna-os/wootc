#!/usr/bin/env python3
"""Validate only the safe native fixture's before/after observations."""
import json
from pathlib import Path
import sys
import uuid


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate fixture observation property')
        result[key] = value
    return result


def protector_identities(value, allow_empty=False):
    if value is None and allow_empty:
        value = []
    if not isinstance(value, list) or len(value) > 2 or (not allow_empty and len(value) != 2):
        raise ValueError('Invalid secure protector observations')
    identities = set()
    types = set()
    ids = set()
    for protector in value:
        if not isinstance(protector, dict) or set(protector) != {'id', 'type'} or protector['type'] not in {'Tpm', 'RecoveryPassword'}:
            raise ValueError('Unexpected protector properties/type')
        identifier = uuid.UUID(protector['id'])
        if identifier.int == 0 or str(identifier) != protector['id'] or identifier in ids or protector['type'] in types:
            raise ValueError('Invalid or ambiguous protector identity')
        ids.add(identifier)
        types.add(protector['type'])
        identities.add((protector['id'], protector['type']))
    return identities


def validate(path):
    if path.stat().st_size > 16384:
        raise ValueError('Oversized fixture receipt')
    lines = [line.strip() for line in path.read_text().splitlines() if line.strip()]
    if len(lines) != 2 or not lines[0].startswith('bitlocker-fixture-metadata '):
        raise ValueError('Missing before/final fixture observations')
    before = json.loads(lines[0].split(' ', 1)[1], object_pairs_hook=unique_object)
    final = json.loads(lines[1], object_pairs_hook=unique_object)
    for observation in [before, final]:
        if type(observation.get('schemaVersion')) is not int or observation.get('schemaVersion') != 1 or observation.get('mountPoint') != 'C:' or observation.get('volumeStatus') != 'FullyEncrypted' or type(observation.get('percentage')) is not int or observation.get('percentage') != 100:
            raise ValueError('Wrong fixture volume or conversion')
    fields = {'schemaVersion', 'mountPoint', 'volumeStatus', 'percentage', 'protection', 'tpmPresent', 'tpmReady', 'protectors'}
    if set(before) != fields | {'stage'} or set(final) != fields | {'ready'}:
        raise ValueError('Unexpected fixture receipt properties')
    if any(before.get(field) is not True for field in ['tpmPresent', 'tpmReady']):
        raise ValueError('No initial ready TPM observation')
    if before.get('stage') != 'before' or before.get('protection') not in {'On', 'Off'}:
        raise ValueError('Missing before state')
    if final.get('protection') != 'On' or any(final.get(field) is not True for field in ['ready', 'tpmPresent', 'tpmReady']):
        raise ValueError('No protected final fixture/TPM observation')
    initial_identities = protector_identities(before['protectors'], allow_empty=True)
    final_identities = protector_identities(final['protectors'])
    if not initial_identities.issubset(final_identities):
        raise ValueError('An existing secure protector changed during activation')



if __name__ == '__main__':
    try:
        validate(Path(sys.argv[1]))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        print('Fixture activation receipt rejected', file=sys.stderr)
        sys.exit(1)
