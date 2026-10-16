#!/usr/bin/env python3
"""Validate one actual successful Windows servicing observation."""
import json
import sys


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate servicing field')
        result[key] = value
    return result


def validate(raw):
    value = json.loads(raw, object_pairs_hook=strict_object)
    if not isinstance(value, dict) or set(value) != {'schemaVersion', 'os', 'pending'}:
        raise ValueError('invalid servicing fields')
    if type(value['schemaVersion']) is not int or value['schemaVersion'] != 1 or value['os'] != 'Windows_NT':
        raise ValueError('unverified Windows servicing identity/schema')
    pending = value['pending']
    if not isinstance(pending, list) or any(type(item) is not str or item not in {'servicing', 'windows-update'} for item in pending):
        raise ValueError('invalid servicing state')
    if len(pending) != len(set(pending)):
        raise ValueError('duplicate servicing state')
    return 'pending:' + ','.join(sorted(pending)) if pending else 'clean'


if __name__ == '__main__':
    try:
        print(validate(sys.stdin.read()))
    except (ValueError, TypeError):
        print('Invalid or missing Windows servicing observation', file=sys.stderr)
        sys.exit(1)
