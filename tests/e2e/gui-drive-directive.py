#!/usr/bin/env python3
"""Build this run's GUI install directive for the frontend being driven.

usage: gui-drive-directive.py <wails|native> <run-id> <directive-id> <image>
Prints the directive as base64 so the guest write can verify it byte for byte.

The legacy Wails frontend gets exactly the directive it always got. The native
shell refuses an install directive that names no target volume
(shell/Wootc.Shell.Core/E2EDrive.cs), so its directive names C:, the system
volume of every harness guest. The shared golden
tests/unit/fixtures/e2e-drive/directive-install.json is these bytes.
"""
import base64
import json
import re
import sys

FRONTENDS = ('wails', 'native')
NATIVE_TARGET = 'C:'


def install_directive(frontend, run_id, directive_id, image):
    if frontend not in FRONTENDS:
        raise ValueError('unknown GUI frontend')
    if not run_id or not re.fullmatch(r'[0-9a-f]{32}', directive_id) or not image:
        raise ValueError('invalid GUI directive identity')
    # The native parser bounds the run identity; the Wails loop never did.
    if frontend == 'native' and len(run_id) > 128:
        raise ValueError('run identity too long for the native shell')
    value = dict(schemaVersion=1, runId=run_id, directiveId=directive_id,
                 action='install', image=image, username='wootc',
                 password='wootc-e2e-pass', hostname='wootc-test')
    if frontend == 'native':
        value['storageId'] = NATIVE_TARGET
    return json.dumps(value, separators=(',', ':'))


if __name__ == '__main__':
    try:
        if len(sys.argv) != 5:
            raise ValueError('usage: gui-drive-directive.py <wails|native> <run-id> <directive-id> <image>')
        raw = install_directive(*sys.argv[1:])
    except ValueError as error:
        print(error, file=sys.stderr)
        sys.exit(2)
    print(base64.b64encode(raw.encode()).decode())
