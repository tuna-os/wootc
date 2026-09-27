#!/usr/bin/env python3
"""Retain one bounded, strictly whitelisted current-call before observation."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate property')
        result[key] = value
    return result


def validate(raw, run_guid):
    if not re.fullmatch('[0-9a-f]{32}', run_guid) or not 0 < len(raw) <= 16384:
        raise ValueError('Invalid bounded receipt')
    text = raw.decode('utf-8').rstrip('\r\n')
    value = json.loads(text, object_pairs_hook=unique)
    if json.dumps(value, ensure_ascii=False, separators=(',', ':')) != text:
        raise ValueError('Noncanonical receipt')
    fields = {'schemaVersion', 'stage', 'mountPoint', 'volumeStatus', 'percentage', 'protection', 'tpmPresent', 'tpmReady', 'protectors', 'runId'}
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError('Unexpected receipt shape')
    if type(value['schemaVersion']) is not int or value['schemaVersion'] != 1 or value['stage'] != 'before' or value['runId'] != run_guid or value['mountPoint'] != 'C:' or value['volumeStatus'] != 'FullyEncrypted' or type(value['percentage']) is not int or value['percentage'] != 100 or value['protection'] not in ('On', 'Off'):
        raise ValueError('Wrong before observation')
    if any(value[field] is not None and type(value[field]) is not bool for field in ('tpmPresent', 'tpmReady')):
        raise ValueError('Invalid TPM observation')
    if not isinstance(value['protectors'], list) or len(value['protectors']) > 16:
        raise ValueError('Invalid protectors')
    for protector in value['protectors']:
        if not isinstance(protector, dict) or set(protector) != {'id', 'type'} or protector['type'] not in ('Tpm', 'RecoveryPassword', 'Unknown') or not isinstance(protector['id'], str) or (protector['id'] != 'Invalid' and not re.fullmatch('[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', protector['id'])):
            raise ValueError('Invalid protector projection')
    return text.encode('utf-8')


def exclusive(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def main():
    raw_path, directory, run_guid, guest_path, host_run, source_path = sys.argv[1:]
    with open(raw_path, 'rb') as stream:
        raw = stream.read(16385)
    canonical = validate(raw, run_guid)
    destination = Path(directory)
    destination.mkdir(mode=0o700, exist_ok=True)
    if destination.is_symlink() or destination.stat().st_mode & 0o077:
        raise ValueError('Unsafe retention directory')
    metadata = {'schemaVersion': 1, 'hostRunId': host_run, 'receiptRunId': run_guid, 'guestPath': guest_path, 'sourceSha256': hashlib.sha256(Path(source_path).read_bytes()).hexdigest(), 'rawSha256': hashlib.sha256(raw).hexdigest(), 'canonicalSha256': hashlib.sha256(canonical).hexdigest(), 'observation': 'before-only', 'failureStageKnown': False}
    exclusive(destination / (run_guid + '.raw.json'), raw)
    exclusive(destination / (run_guid + '.json'), canonical)
    exclusive(destination / (run_guid + '.provenance.json'), json.dumps(metadata, separators=(',', ':')).encode())


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, UnicodeError, TypeError, KeyError):
        print('BitLocker before receipt unavailable or rejected', file=sys.stderr)
        sys.exit(1)
