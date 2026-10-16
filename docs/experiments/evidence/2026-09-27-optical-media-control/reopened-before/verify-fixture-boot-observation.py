#!/usr/bin/env python3
"""Require observed Windows boot identity around the owned optical operation."""
import argparse
import json
import re
from pathlib import Path


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate boot observation')
        result[key] = value
    return result


def parse(raw):
    if not 0 < len(raw) <= 4096:
        raise ValueError('Unbounded boot observation')
    value = json.loads(raw.decode('utf-8-sig'), object_pairs_hook=unique)
    if not isinstance(value, dict) or set(value) != {'schemaVersion', 'os', 'bootId'}:
        raise ValueError('Unexpected boot observation')
    if type(value['schemaVersion']) is not int or value['schemaVersion'] != 1 or value['os'] != 'Windows_NT':
        raise ValueError('Unobserved Windows identity')
    if not isinstance(value['bootId'], str) or not re.fullmatch('[0-9]{17,19}', value['bootId']) or int(value['bootId']) <= 0:
        raise ValueError('Unobserved Windows boot identity')
    return value


def compare(before, after, mode, run_id):
    if mode not in ('same', 'changed') or not re.fullmatch('[A-Za-z0-9_-]{1,128}', run_id):
        raise ValueError('Invalid fixture correlation')
    first, second = parse(before), parse(after)
    same = first['bootId'] == second['bootId']
    if same != (mode == 'same'):
        raise ValueError('Required Windows boot transition not observed')
    return {'schemaVersion': 1, 'runId': run_id, 'os': 'Windows_NT', 'beforeBootId': first['bootId'], 'afterBootId': second['bootId'], 'observation': mode}


def main():
    arguments = argparse.ArgumentParser()
    arguments.add_argument('--before', required=True)
    arguments.add_argument('--after', required=True)
    arguments.add_argument('--mode', choices=('same', 'changed'), required=True)
    arguments.add_argument('--run-id', required=True)
    args = arguments.parse_args()
    # Read one byte beyond the bound so oversized input cannot become a prefix.
    with open(args.before, 'rb') as stream:
        before = stream.read(4097)
    with open(args.after, 'rb') as stream:
        after = stream.read(4097)
    print(json.dumps(compare(before, after, args.mode, args.run_id), separators=(',', ':')))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, UnicodeError, TypeError, KeyError):
        raise SystemExit('Windows boot identity unavailable or refused')
