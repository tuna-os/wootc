#!/usr/bin/env python3
"""Validate current successful Phase3 observations; exit 2 is unknown protocol, 3 is observed mismatch."""
import re
import sys
from phase3_ancestry import Ancestry, Mismatch


def parse(raw):
    fields = {}
    for line in raw.splitlines():
        key, sep, value = line.partition('=')
        if not sep or key in fields or (not value and key not in {'PATHS', 'BTRFS'}) or '\x00' in value:
            raise ValueError('Invalid or duplicate field')
        fields[key] = value
    if set(fields) != {'SCHEMA', 'UNAME', 'CMDLINE', 'TARGET', 'BOOT_ID', 'BLOCKS', 'MOUNTS', 'LOOPS', 'PATHS', 'BTRFS'}:
        raise ValueError('Missing or unknown field')
    if fields['SCHEMA'] != '1' or not re.fullmatch(r'[a-zA-Z0-9_-]+', fields['UNAME']):
        raise ValueError('Invalid schema or identity')
    if not re.fullmatch(r'/dev/[a-zA-Z0-9_-]+', fields['TARGET']):
        raise ValueError('Invalid target')
    if not fields['CMDLINE'].strip():
        raise ValueError('Missing current command line')
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
        if len(sys.argv) == 6 and sys.argv[1] == '--userdata':
            with open(sys.argv[2], encoding='utf-8') as proof:
                native = parse(proof.read())
            ancestry = Ancestry(native, sys.argv[4])
            if not verify(native, sys.argv[4]) or native['BOOT_ID'] != sys.argv[5]:
                raise ValueError('Retained native facts are not the validated boot')
            ancestry.verify_root()
            lines = sys.stdin.read().splitlines()
            if len(lines) < 3 or lines[0] != 'SCHEMA=1' or lines[1] != 'UNAME=Linux' or lines[2] != 'BOOT_ID='+native['BOOT_ID']:
                raise ValueError('User data identity is not the observed native boot')
            for index, key in enumerate(('BLOCKS', 'MOUNTS', 'LOOPS', 'PATHS', 'BTRFS'), start=3):
                if len(lines) <= index or not lines[index].startswith(key+'='):
                    raise ValueError('Current data mount/block observations unavailable')
                native[key] = lines[index][len(key)+1:]
            ancestry = Ancestry(native, sys.argv[4])
            ancestry.verify_root()
            if len(lines) < 13 or lines[8] != 'EXPORT_SCHEMA=1' or lines[9] != 'EXPORT_BOOT_ID='+native['BOOT_ID']:
                raise ValueError('Export is not from the observed current boot')
            if not lines[10].startswith('SRC=') or not lines[11].startswith('DATA_MAJ_MIN=') or not lines[12].startswith('DATA_MOUNT='):
                raise ValueError('Export mount row unavailable')
            ancestry.verify_data(lines[10][4:], lines[11][13:], lines[12][11:])
            if len(lines) != 14 or lines[13] != 'wootc-e2e-userdata '+sys.argv[3]:
                print('Current native seed content is absent or differs', file=sys.stderr)
                sys.exit(3)
            print(lines[10])
            sys.exit(0)
        if len(sys.argv) != 2 or not re.fullmatch(r'/dev/[a-zA-Z0-9_-]+', sys.argv[1]):
            raise ValueError('Invalid expected target')
        facts = parse(sys.stdin.read())
        ancestry = Ancestry(facts, sys.argv[1])
        ancestry.verify_root()
    except Mismatch:
        print('Current backing does not belong to the native target', file=sys.stderr)
        sys.exit(3)
    except (ValueError, KeyError, TypeError, OSError):
        print('Invalid Phase 3 native observation protocol', file=sys.stderr)
        sys.exit(2)
    if not verify(facts, sys.argv[1]):
        print('Phase 3 native observations disagree with expected native boot', file=sys.stderr)
        sys.exit(3)
    print(facts['BOOT_ID'])
