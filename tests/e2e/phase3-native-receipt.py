#!/usr/bin/env python3
"""Validate current successful Phase3 observations; exit 2 means invalid protocol."""
import re
import sys


def parse(raw):
    fields = {}
    for line in raw.splitlines():
        key, sep, value = line.partition('=')
        if not sep or key in fields or not value or '\x00' in value:
            raise ValueError('Invalid or duplicate field')
        fields[key] = value
    if set(fields) != {'SCHEMA', 'UNAME', 'CMDLINE', 'TARGET', 'BOOT_ID'}:
        raise ValueError('Missing or unknown field')
    if fields['SCHEMA'] != '1' or not re.fullmatch(r'[a-zA-Z0-9_-]+', fields['UNAME']):
        raise ValueError('Invalid schema or identity')
    if not re.fullmatch(r'/dev/[a-zA-Z0-9_-]+', fields['TARGET']):
        raise ValueError('Invalid target')
    if not re.fullmatch(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', fields['BOOT_ID']):
        raise ValueError('Invalid boot identity')
    return fields


def verify(fields, target):
    if fields['UNAME'] != 'Linux' or fields['TARGET'] != target:
        return False
    return not any(token.split('=', 1)[0] in {'loop', 'wootc.rootdisk'}
                   for token in fields['CMDLINE'].split())


if __name__ == '__main__':
    try:
        if len(sys.argv) == 4 and sys.argv[1] == '--userdata':
            lines = sys.stdin.read().splitlines()
            if len(lines) < 3 or lines[0] != 'SCHEMA=1' or lines[1] != 'UNAME=Linux' or lines[2] != 'BOOT_ID='+sys.argv[2]:
                raise ValueError('User data identity is not the observed native boot')
            if len(lines) != 5 or not lines[3].startswith('SRC=') or not lines[3][4:] or lines[4] != 'wootc-e2e-userdata '+sys.argv[3]:
                print('Current native seed content is absent or differs', file=sys.stderr)
                sys.exit(1)
            print(lines[3])
            sys.exit(0)
        if len(sys.argv) != 2 or not re.fullmatch(r'/dev/[a-zA-Z0-9_-]+', sys.argv[1]):
            raise ValueError('Invalid expected target')
        facts = parse(sys.stdin.read())
    except ValueError:
        print('Invalid Phase 3 native observation protocol', file=sys.stderr)
        sys.exit(2)
    if not verify(facts, sys.argv[1]):
        print('Phase 3 native observations disagree with expected native boot', file=sys.stderr)
        sys.exit(1)
    print(facts['BOOT_ID'])
