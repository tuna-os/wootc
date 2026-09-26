#!/usr/bin/env python3
"""Conservative result adapter for legacy import helpers.

Legacy helpers do not return per-item evidence. Their zero exit means only that
execution returned, so never synthesize a migrated list or verified success.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def write_result(directory, result):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Replace stale success as a whole record; never leave half-written JSON.
    fd, temporary = tempfile.mkstemp(prefix='.status-', dir=directory)
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(result, out)
            out.write('\n')
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, directory / 'status.json')
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir', required=True)
    parser.add_argument('--require-source-user', action='store_true')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    directory = Path(args.state_dir)
    write_result(directory, {'status': 'partial', 'migrated': [], 'verified': False,
                             'note': 'Import started; no verified result yet.'})
    result = {'status': 'failed', 'migrated': [], 'verified': False}
    rc = 1
    if args.require_source_user and not os.environ.get('WOOTC_WIN_USER'):
        result['note'] = 'No Windows profile selected; nothing was imported.'
    elif not args.command or not shutil.which(args.command[0]):
        result['note'] = 'The import helper is unavailable; nothing was imported.'
    else:
        try:
            completed = subprocess.run(args.command, check=False)
            rc = completed.returncode
            if rc == 0:
                result.update(status='partial', note='The import helper finished. Item-level verification is not available; review the app before relying on this import.')
            else:
                result['note'] = 'The import helper failed; some changes may exist. Review the app before retrying.'
            result['helperExitCode'] = rc
        except OSError:
            result['note'] = 'The import helper could not start; nothing was imported.'
            rc = 1
    write_result(directory, result)
    return 0 if rc == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
