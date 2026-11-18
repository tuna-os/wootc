#!/usr/bin/env python3
"""Validate layer handoffs; results.py remains the only run-result authority."""
import datetime
import json
import os
import sys
import results

LIMIT = 65536


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate evidence field')
        result[key] = value
    return result


def decode(text):
    if not text or len(text.encode()) > LIMIT:
        raise ValueError('missing or oversized evidence')
    value = json.loads(text, object_pairs_hook=unique)
    if not isinstance(value, dict):
        raise ValueError('evidence is not an object')
    return value


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError('missing evidence time')
    result = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('ambiguous evidence time')
    return result


def validate_qga(info):
    if not isinstance(info.get('version'), str) or not info['version'].strip():
        raise ValueError('guest-info has no version')
    commands = info.get('supported_commands')
    if not isinstance(commands, list) or not commands:
        raise ValueError('guest-info has no command inventory')
    enabled = {command.get('name') for command in commands
               if isinstance(command, dict) and command.get('enabled') is True
               and isinstance(command.get('name'), str)}
    if not {'guest-info', 'guest-exec', 'guest-exec-status'}.issubset(enabled):
        raise ValueError('guest-info lacks required control-plane commands')
    return 'guest-info-observed'


def validated_handoff(ledger, run, route, marker):
    fd = os.open(ledger, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, encoding='utf-8') as stream:
        results.regular(stream.fileno())
        rows = results.load(stream, run)
    resets = [row['sequence'] for row in rows if row.get('kind') == 'assertion'
              and row.get('domain') == 'infrastructure'
              and row.get('assertionId') == 'layer-fixture-reset']
    if not resets:
        raise ValueError('no current-run fixture reset')
    if route == 'oem' and marker == run:
        assertion, domain = 'layer-windows-oem', 'product'
    elif route == 'gui' and marker == '':
        assertion, domain = 'gui-install', 'product'
    else:
        raise ValueError('invalid handoff authority')
    if not any(row.get('kind') == 'assertion' and row.get('domain') == domain
               and row.get('assertionId') == assertion
               and row['sequence'] > max(resets) for row in rows):
        raise ValueError('no current-run authenticated handoff')


def validate_deployer(ledger, run, route, marker, image, not_before, started, state):
    validated_handoff(ledger, run, route, marker)
    if not image or started.get('image') != image:
        raise ValueError('deployer image does not match')
    began = timestamp(started.get('startedAt'))
    updated = timestamp(state.get('updatedAt'))
    earliest = timestamp(not_before)
    now = datetime.datetime.now(datetime.timezone.utc)
    if not earliest <= began <= updated <= now:
        raise ValueError('deployer evidence is stale or clock order is unknown')
    if state.get('updatedBy') != 'wootc-deployer':
        raise ValueError('lifecycle writer is not the deployer')
    if state.get('state') not in {'deploying', 'deployed', 'failed'}:
        raise ValueError('no deployer lifecycle observation')
    # Even deployed here is not installed-boot/root/user-data proof. That remains
    # the full-cycle assertions and verified first-boot assessment's job.
    return 'deployer-failed' if state['state'] == 'failed' else 'deployer-observed'


def main():
    try:
        operation = sys.argv[1]
        if operation == 'qga' and len(sys.argv) == 2:
            result = validate_qga(decode(sys.stdin.read(LIMIT + 1)))
        elif operation == 'deployer' and len(sys.argv) == 10:
            ledger, run, route, marker, image, earliest, started, state = sys.argv[2:]
            with open(started, encoding='utf-8') as stream:
                started_record = decode(stream.read(LIMIT + 1))
            with open(state, encoding='utf-8') as stream:
                state_record = decode(stream.read(LIMIT + 1))
            result = validate_deployer(ledger, run, route, marker, image, earliest,
                                       started_record, state_record)
        else:
            raise ValueError('invalid evidence request')
        print(result)
        return 0
    except (OSError, ValueError, TypeError, KeyError, IndexError):
        # Never repeat raw guest data, lifecycle errors or source paths.
        print('Layer evidence rejected', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
