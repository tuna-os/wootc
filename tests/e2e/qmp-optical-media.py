#!/usr/bin/env python3
"""Observe and eject only explicitly owned optical media; never infer success."""
import argparse
import json
import math
import os
import stat
import re
import socket
import sys
import time


class Refusal(ValueError):
    pass


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refusal('Duplicate QMP field')
        result[key] = value
    return result


class QMP:
    def __init__(self, path, timeout):
        if not math.isfinite(timeout) or not 0 < timeout <= 15:
            raise Refusal('Timeout must be positive and at most 15 seconds')
        parent = os.path.dirname(path)
        directory = os.lstat(parent)
        endpoint = os.lstat(path)
        if not stat.S_ISDIR(directory.st_mode) or stat.S_IMODE(directory.st_mode) != 0o700 or directory.st_uid != os.geteuid():
            raise Refusal('QMP parent is not private and owned')
        if not stat.S_ISSOCK(endpoint.st_mode) or endpoint.st_uid != os.geteuid():
            raise Refusal('QMP endpoint is not an owned socket')
        self.deadline = time.monotonic()+timeout
        self.socket = socket.socket(socket.AF_UNIX)
        self.buffer = b''
        self.sequence = 0
        try:
            self.bound()
            self.socket.connect(path)
            greeting = self.read()
            if not isinstance(greeting, dict) or not isinstance(greeting.get('QMP'), dict):
                raise Refusal('Missing QMP greeting')
            if self.command('qmp_capabilities') != {}:
                raise Refusal('Invalid QMP capability acknowledgment')
        except BaseException:
            self.socket.close()
            raise

    def bound(self):
        remaining = self.deadline-time.monotonic()
        if remaining <= 0:
            raise Refusal('QMP deadline expired')
        self.socket.settimeout(remaining)

    def read(self):
        while b'\n' not in self.buffer:
            self.bound()
            chunk = self.socket.recv(65536)
            if not chunk:
                raise Refusal('QMP channel closed')
            self.buffer += chunk
            if len(self.buffer) > 1_000_000:
                raise Refusal('QMP response exceeds bound')
        line, self.buffer = self.buffer.split(b'\n', 1)
        return json.loads(line, object_pairs_hook=unique)

    def command(self, name, arguments=None):
        self.sequence += 1
        token = 'optical-'+str(self.sequence)
        request = {'execute': name, 'id': token}
        if arguments is not None:
            request['arguments'] = arguments
        self.bound()
        self.socket.sendall((json.dumps(request)+'\n').encode())
        for _ in range(128):
            response = self.read()
            if not isinstance(response, dict):
                raise Refusal('Invalid QMP response')
            if 'event' in response and 'id' not in response:
                continue
            if response.get('id') != token or 'error' in response or 'return' not in response:
                raise Refusal('Failed or uncorrelated QMP command')
            return response['return']
        raise Refusal('QMP events exceed bound')

    def close(self):
        self.socket.close()


def observe(qmp, allowed):
    rows = qmp.command('query-block')
    if not isinstance(rows, list) or not rows or len(rows) > 128:
        raise Refusal('Missing or oversized block observations')
    result, names, paths = [], set(), set()
    for row in rows:
        if not isinstance(row, dict) or type(row.get('removable')) is not bool:
            raise Refusal('Invalid removable-device observation')
        name = row.get('device')
        if not isinstance(name, str) or not name or name in names:
            raise Refusal('Missing or duplicate block device')
        names.add(name)
        if not row['removable']:
            continue
        path = row.get('qdev')
        if not isinstance(path, str) or not re.fullmatch(r'/[A-Za-z0-9_./\[\]-]+', path) or path in paths:
            raise Refusal('Missing or ambiguous removable guest device')
        paths.add(path)
        kind = qmp.command('qom-get', {'path': path, 'property': 'type'})
        if kind not in ('ide-cd', 'scsi-cd'):
            raise Refusal('Unsupported removable guest-device type')
        boot = qmp.command('qom-get', {'path': path, 'property': 'bootindex'})
        if type(boot) is not int or not -1 <= boot <= 65535:
            raise Refusal('Invalid optical boot index')
        inserted = row.get('inserted')
        medium = None
        if 'inserted' in row:
            if not isinstance(inserted, dict) or inserted.get('ro') is not True:
                raise Refusal('Inserted optical medium is not observed read-only')
            medium = inserted.get('file')
            if medium not in allowed:
                raise Refusal('Inserted optical medium is outside the owned allowlist')
        result.append({'device': name, 'qdev': path, 'type': kind, 'bootIndex': boot, 'medium': medium})
    if not result:
        raise Refusal('No positively observed optical device')
    return result


def detach(qmp, allowed):
    if not allowed or len(allowed) > 8 or len(set(allowed)) != len(allowed):
        raise Refusal('Missing or ambiguous owned-media allowlist')
    for path in allowed:
        if not re.fullmatch(r'/[A-Za-z0-9_./-]+\.iso', path) or '..' in path.split('/'):
            raise Refusal('Invalid owned optical-media path')
    before = observe(qmp, set(allowed))
    removed = []
    for row in before:
        if row['medium'] is None:
            continue
        if qmp.command('eject', {'id': row['qdev'], 'force': False}) != {}:
            raise Refusal('Invalid optical-eject acknowledgment')
        removed.append(row['qdev'])
    after = observe(qmp, set(allowed))
    def identities(rows):
        return {(row['device'], row['qdev'], row['type'], row['bootIndex']) for row in rows}
    if identities(before) != identities(after) or any(row['medium'] is not None for row in after):
        raise Refusal('Optical identity changed or medium remains inserted')
    return {'schema': 1, 'before': before, 'removed': removed, 'after': after, 'empty': True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--socket', required=True)
    parser.add_argument('--timeout', type=float, default=15)
    parser.add_argument('--allow', action='append', required=True)
    args = parser.parse_args()
    qmp = None
    try:
        qmp = QMP(args.socket, args.timeout)
        receipt = detach(qmp, args.allow)
    except (Refusal, OSError, ValueError, TypeError, RecursionError):
        print('Optical-media observation or removal refused', file=sys.stderr)
        return 1
    finally:
        if qmp:
            qmp.close()
    print(json.dumps(receipt, separators=(',', ':')))
    return 0


if __name__ == '__main__':
    sys.exit(main())
