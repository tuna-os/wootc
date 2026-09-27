#!/usr/bin/env python3
"""Validate a successful read-only Windows boot observation; no cached facts."""
import json
import re
import sys

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate field')
        result[key] = value
    return result

def parse(raw):
    record = json.loads(raw, object_pairs_hook=unique_object)
    if not isinstance(record, dict) or set(record) != {'schemaVersion', 'os', 'bootId'}:
        raise ValueError('Invalid fields')
    if type(record['schemaVersion']) is not int or record['schemaVersion'] != 1:
        raise ValueError('Invalid schema')
    if record['os'] != 'Windows_NT' or not isinstance(record['bootId'], str):
        raise ValueError('Invalid identity')
    if not re.fullmatch(r'[1-9][0-9]{8,18}', record['bootId']):
        raise ValueError('Invalid boot token')
    return record['bootId']

if __name__ == '__main__':
    try:
        print(parse(sys.stdin.read()))
    except (ValueError, TypeError, KeyError):
        print('Invalid or missing Windows boot observation', file=sys.stderr)
        sys.exit(1)
