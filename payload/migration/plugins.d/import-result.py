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
import pwd
import stat
import uuid
import sys


def write_result(directory, result):
    # Home aliases (/home -> /var/home on Fedora) are resolved only at the
    # account root. Never resolve an attacker-controlled .config/state symlink.
    original_uid, original_gid = os.geteuid(), os.getegid()
    parent = None
    try:
        try:
            account = pwd.getpwnam(os.environ.get('WOOTC_LINUX_USER', ''))
        except KeyError:
            account = None
        if account is not None:
            account_home = Path(account.pw_dir)
            if directory.is_relative_to(account_home):
                directory = account_home.resolve(strict=True) / directory.relative_to(account_home)
                if original_uid == 0:
                    os.setegid(account.pw_gid)
                    os.seteuid(account.pw_uid)
        if '..' in directory.parts:
            raise ValueError('unsafe import result directory')
        parent = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
        for component in directory.absolute().parts[1:]:
            try:
                os.mkdir(component, mode=0o700, dir_fd=parent)
            except FileExistsError:
                pass
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        try:
            info = os.stat('status.json', dir_fd=parent, follow_symlinks=False)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid():
                raise ValueError('unsafe existing import result')
        except FileNotFoundError:
            pass
        temporary = '.status-' + uuid.uuid4().hex
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=parent)
        try:
            with os.fdopen(fd, 'w') as out:
                json.dump(result, out)
                out.write('\n')
                out.flush()
                os.fsync(out.fileno())
            os.replace(temporary, 'status.json', src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
        finally:
            try:
                os.unlink(temporary, dir_fd=parent)
            except FileNotFoundError:
                pass
    finally:
        if parent is not None:
            os.close(parent)
        if original_uid == 0:
            os.seteuid(original_uid)
            os.setegid(original_gid)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-dir', required=True)
    parser.add_argument('--require-source-user', action='store_true')
    parser.add_argument('--result-json', action='store_true',
                        help='require the helper to return explicit per-item JSON outcomes')
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
            completed = subprocess.run(args.command, check=False,
                                       capture_output=args.result_json, text=args.result_json)
            rc = completed.returncode
            if args.result_json:
                if completed.stderr:
                    print(completed.stderr, end='', file=sys.stderr)
                try:
                    evidence = json.loads(completed.stdout)
                    if (not isinstance(evidence, dict) or
                            evidence.get('status') not in ('success', 'partial', 'failed', 'unchanged') or
                            any(not isinstance(evidence.get(key), list)
                                for key in ('migrated', 'alreadyPresent', 'preserved', 'failed')) or
                            any(not isinstance(value, str) for value in evidence['migrated'])):
                        raise ValueError('invalid item result')
                    result.update(evidence)
                    result['verified'] = False  # copied files do not prove app acceptance
                    if rc or evidence['failed'] or evidence['status'] == 'failed':
                        result['status'] = 'failed'
                        rc = rc or 1
                    elif evidence['status'] == 'success' and not (evidence['migrated'] or evidence['alreadyPresent']):
                        raise ValueError('success without completed items')
                except (ValueError, TypeError):
                    result.update(status='failed', migrated=[], verified=False,
                                  note='The helper returned no valid item-level result; review the app before retrying.')
                    rc = rc or 1
            elif rc == 0:
                result.update(status='partial', note='The import helper finished. Item-level verification is not available; review the app before relying on this import.')
            else:
                result['note'] = 'The import helper failed; some changes may exist. Review the app before retrying.'
            result['helperExitCode'] = completed.returncode
        except OSError:
            result['note'] = 'The import helper could not start; nothing was imported.'
            rc = 1
    write_result(directory, result)
    return 0 if rc == 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
