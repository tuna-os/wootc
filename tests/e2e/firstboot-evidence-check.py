#!/usr/bin/env python3
"""Check the product's first-boot evidence against what the harness observed.

Usage: firstboot-evidence-check.py EVIDENCE_JSON SELECTED_IMAGE PHASE2_BOOT_ID

The harness reads installed-linux-boot.json back from Windows after the
Phase-2 boot and compares it with its own observations: the image it asked
for, and the kernel boot ID it read from the Phase-2 guest. A record left by
any other boot or install fails. An empty PHASE2_BOOT_ID (the guest could not
be asked) skips only that comparison, and says so.

Exit 0: matches. Exit 3: readable but describes something else. Exit 2:
missing, oversized or malformed.
"""
import json
import re
import sys

LIMIT = 16 * 1024


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    path, image, boot_id = argv[1], argv[2], argv[3].strip().lower()
    try:
        with open(path, 'rb') as stream:
            data = stream.read(LIMIT + 1)
        if len(data) > LIMIT:
            raise ValueError('larger than %d bytes' % LIMIT)
        record = json.loads(data.decode('utf-8-sig'))
        if not isinstance(record, dict):
            raise ValueError('not an object')
        shape = (record['schema'], record['state'], record['bootId'], record['kernel'],
                 record['image']['ref'], record['image']['digest'], record['rootDisk']['path'],
                 record['rootDisk']['hostUuid'], record['bridge']['boundFolders'], record['secureBoot'])
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('[evidence] unreadable first-boot evidence: %s' % error)
        return 2
    print('[evidence] kernel=%s image=%s digest=%s sourceRef=%s bootId=%s host=%s boundFolders=%s secureBoot=%s'
          % (shape[3], shape[4], shape[5], record['image'].get('sourceRef', ''), shape[2], shape[7], shape[8], shape[9]))
    problems = []
    if shape[0] != 1 or shape[1] != 'healthy':
        problems.append('schema/state is %r/%r' % shape[:2])
    if image not in (shape[4], record['image'].get('sourceRef')):
        problems.append('image %s (source %s) is not the selected %s'
                        % (shape[4], record['image'].get('sourceRef'), image))
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', str(shape[5])):
        problems.append('digest %r is not a sha256 digest' % shape[5])
    if shape[6] != '/wootc/disks/root.disk' or not re.fullmatch('[0-9A-F]{16}', str(shape[7])):
        problems.append('root.disk identity %r/%r' % shape[6:8])
    if boot_id:
        if shape[2] != boot_id:
            problems.append('written by boot %s, not the observed Phase-2 boot %s' % (shape[2], boot_id))
    else:
        print('[evidence] Phase-2 boot ID was not observed; boot identity not compared')
    for problem in problems:
        print('[evidence] MISMATCH: ' + problem)
    return 3 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
