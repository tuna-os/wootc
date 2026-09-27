#!/usr/bin/env python3
"""Validate the bounded current-call optical observation before Windows use."""
import argparse
import hashlib
import os
from pathlib import Path
import json
import re


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate optical observation')
        result[key] = value
    return result


def validate(raw, allowed, mode="detach", prior=None):
    if not 0 < len(raw) <= 65536 or not allowed:
        raise ValueError('Unbounded optical observation')
    value = json.loads(raw, object_pairs_hook=unique)
    fields={'schema','before','removed','after','empty'}
    if mode == 'check-empty':
        fields.add('operation')
    elif mode != 'detach':
        raise ValueError('Unknown optical operation')
    if not isinstance(value, dict) or set(value) != fields or type(value['schema']) is not int or value['schema'] != 1 or value['empty'] is not True:
        raise ValueError('Missing optical removal observation')
    if mode == 'check-empty' and value['operation'] != 'check-empty':
        raise ValueError('Unobserved read-only optical operation')
    identities = []
    inserted = set()
    for phase in ('before', 'after'):
        rows = value[phase]
        if not isinstance(rows, list) or not 0 < len(rows) <= 128:
            raise ValueError('Missing optical identities')
        identity, names, paths = set(), set(), set()
        for row in rows:
            if not isinstance(row, dict) or set(row) != {'device', 'qdev', 'type', 'bootIndex', 'medium'}:
                raise ValueError('Unexpected optical shape')
            if not isinstance(row['device'], str) or not re.fullmatch('[A-Za-z0-9_.-]{1,128}', row['device']) or not isinstance(row['qdev'], str) or not re.fullmatch(r'/[A-Za-z0-9_./\[\]-]{1,512}', row['qdev']) or row['type'] not in ('ide-cd', 'scsi-cd') or type(row['bootIndex']) is not int or not -1 <= row['bootIndex'] <= 65535:
                raise ValueError('Unknown optical identity')
            key = (row['device'], row['qdev'], row['type'], row['bootIndex'])
            if key in identity or row['device'] in names or row['qdev'] in paths:
                raise ValueError('Duplicate optical identity')
            identity.add(key)
            names.add(row['device'])
            paths.add(row['qdev'])
            if row['medium'] is not None:
                if mode == 'check-empty' or phase == 'after' or row['medium'] not in allowed:
                    raise ValueError('Unknown or retained optical medium')
                inserted.add(row['qdev'])
        identities.append(identity)
    removed = value['removed']
    if identities[0] != identities[1] or not isinstance(removed, list) or any(not isinstance(item, str) for item in removed) or len(set(removed)) != len(removed) or set(removed) != inserted:
        raise ValueError('Unobserved exact optical removal')
    if mode == 'check-empty':
        if prior is None:
            raise ValueError('Missing previous optical identity')
        old = validate(prior, allowed)
        old_identities = {(row['device'],row['qdev'],row['type'],row['bootIndex']) for row in old['after']}
        if identities[0] != old_identities:
            raise ValueError('Optical identity changed since removal')
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('receipt')
    parser.add_argument('--allow', action='append', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--source', required=True)
    parser.add_argument('--context', required=True)
    parser.add_argument('--mode', choices=('detach','check-empty'), default='detach')
    parser.add_argument('--prior')
    args = parser.parse_args()
    previous=None
    if args.prior:
        with open(args.prior,'rb') as stream:
            previous=stream.read(65537)
    with open(args.receipt, 'rb') as stream:
        value = validate(stream.read(65537), set(args.allow), args.mode, previous)
    if not re.fullmatch('[A-Za-z0-9_-]{1,128}', args.run_id):
        raise ValueError('Invalid optical correlation')
    canonical = json.dumps(value, sort_keys=True, separators=(',', ':')).encode()
    context = {'schemaVersion': 1, 'runId': args.run_id, 'sourceSha256': hashlib.sha256(Path(args.source).read_bytes()).hexdigest(), 'canonicalObservationSha256': hashlib.sha256(canonical).hexdigest(), 'canonicalization': 'sorted-json-compact-utf8', 'observation': 'owned-optical-empty-readback', 'operation': args.mode}
    descriptor = os.open(args.context, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(json.dumps(context, separators=(',', ':')).encode())
        stream.flush()
        os.fsync(stream.fileno())
    print(json.dumps(value, separators=(',', ':')))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, UnicodeError, TypeError, KeyError):
        raise SystemExit('Optical removal receipt unavailable or refused')
