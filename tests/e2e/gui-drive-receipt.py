#!/usr/bin/env python3
"""Validate a current GUI drive observation before the scenario uses it."""
import json
import re
import sys

FIELDS = {'schemaVersion', 'runId', 'directiveId', 'action', 'screen',
          'installDriven', 'installBtnDisabled', 'hint', 'progressStep',
          'error', 'selectedRef', 'imageMismatch'}
SCREENS = {'loading', 'launchpad', 'progress', 'done', 'control', 'migrate',
           'recovery', 'vmpreview'}


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('duplicate GUI field')
        value[key] = item
    return value


def validate(raw, run_id, directive_id, image):
    if not run_id or not re.fullmatch(r'[0-9a-f]{32}', directive_id) or not image:
        raise ValueError('invalid expected GUI identity')
    if len(raw.encode('utf-8')) > 16384:
        raise ValueError('oversized GUI observation')
    value = json.loads(raw, object_pairs_hook=unique_object)
    if not isinstance(value, dict) or set(value) != FIELDS:
        raise ValueError('invalid GUI fields')
    if type(value['schemaVersion']) is not int or value['schemaVersion'] != 1:
        raise ValueError('invalid GUI schema')
    if (value['runId'], value['directiveId'], value['action']) != (run_id, directive_id, 'install'):
        raise ValueError('stale or unrelated GUI observation')
    if type(value['screen']) is not str or value['screen'] not in SCREENS:
        raise ValueError('unknown GUI screen')
    if any(type(value[key]) is not bool for key in ('installDriven', 'imageMismatch')):
        raise ValueError('invalid GUI boolean')
    if value['installBtnDisabled'] is not None and type(value['installBtnDisabled']) is not bool:
        raise ValueError('invalid button observation')
    if any(type(value[key]) is not str for key in ('hint', 'progressStep', 'selectedRef')):
        raise ValueError('invalid GUI text observation')
    if value['error'] is not None and (type(value['error']) is not str or not value['error']):
        raise ValueError('invalid GUI error observation')
    driven, screen = value['installDriven'], value['screen']
    if driven and (value['selectedRef'] != image or value['imageMismatch']):
        raise ValueError('install identity changed')
    if screen == 'done' and (not driven or value['error'] is not None):
        raise ValueError('contradictory completed install')
    if value['imageMismatch'] and (screen != 'launchpad' or driven or value['selectedRef'] == image):
        raise ValueError('contradictory image refusal')
    # Canonical JSON also makes newlines/quotes inside text unable to impersonate
    # a screen or boolean when consumed by the scenario.
    return json.dumps(value, separators=(',', ':'), ensure_ascii=True)


if __name__ == '__main__':
    try:
        if len(sys.argv) != 4:
            raise ValueError('missing expected GUI identity')
        raw = sys.stdin.buffer.read(16385)
        if len(raw) > 16384:
            raise ValueError('oversized GUI receipt')
        print(validate(raw.decode('utf-8'), *sys.argv[1:]))
    except (ValueError, TypeError, UnicodeError):
        print('GUI drive observation unavailable or invalid', file=sys.stderr)
        sys.exit(1)
