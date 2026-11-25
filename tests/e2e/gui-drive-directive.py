#!/usr/bin/env python3
"""Build this run's GUI install directive for the frontend being driven.

usage: gui-drive-directive.py <wails|native> <run-id> <directive-id> <image>
       gui-drive-directive.py --manifest <wails|native>
Prints the directive as base64 so the guest write can verify it byte for byte;
--manifest prints the migration-manifest header lines (tests/e2e/lib/
migration.sh) that record what this frontend's directive chose.

The legacy Wails frontend gets exactly the directive it always got. The native
shell refuses an install directive that names no target volume
(shell/Wootc.Shell.Core/E2EDrive.cs), so its directive names C:, the system
volume of every harness guest. It also names the Linux disk size: the shell's
35 GB default plus the ~23 GB an image needs to unpack fills the 80 GB guest's
~58 GB free exactly, and the engine's check at install time refused it by 1 GB
(run 44720556894).

The native directive also sets the rest of the form the way a person
migrating would: Windows-Style Mode on (the shell's default is off, and only
that mode collects the time zone, keyboard and wallpaper), and of the Windows
apps the engine detects from tests/e2e/oem/seed-profile.ps1 it keeps Audacity
and Inkscape and unchecks GIMP, so the installed system must carry exactly
the kept apps. The shared golden tests/unit/fixtures/e2e-drive/
directive-install.json is these bytes.
"""
import base64
import json
import re
import sys

FRONTENDS = ('wails', 'native')
NATIVE_TARGET = 'C:'
NATIVE_DISK_GB = 30
NATIVE_WINDOWS_LOOK = True
NATIVE_FLATPAKS = ('org.audacityteam.Audacity', 'org.inkscape.Inkscape')
# Detected on Windows (seed-profile.ps1 registers GIMP) and left unchecked.
NATIVE_DESELECTED = ('org.gimp.GIMP',)


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
        value['diskSizeGb'] = NATIVE_DISK_GB
        value['windowsLook'] = NATIVE_WINDOWS_LOOK
        value['flatpaks'] = list(NATIVE_FLATPAKS)
    return json.dumps(value, separators=(',', ':'))


def manifest_headers(frontend):
    """What the directive chose, as migration-manifest headers. The Wails
    directive sets neither key, so it records nothing."""
    if frontend not in FRONTENDS:
        raise ValueError('unknown GUI frontend')
    if frontend != 'native':
        return []
    return [f'#windowsLook={1 if NATIVE_WINDOWS_LOOK else 0}',
            '#flatpaksSelected=' + ','.join(NATIVE_FLATPAKS),
            '#flatpaksDeselected=' + ','.join(NATIVE_DESELECTED)]


if __name__ == '__main__':
    try:
        if len(sys.argv) == 3 and sys.argv[1] == '--manifest':
            headers = manifest_headers(sys.argv[2])
            if headers:
                print('\n'.join(headers))
            sys.exit(0)
        if len(sys.argv) != 5:
            raise ValueError('usage: gui-drive-directive.py <wails|native> <run-id> <directive-id> <image>')
        raw = install_directive(*sys.argv[1:])
    except ValueError as error:
        print(error, file=sys.stderr)
        sys.exit(2)
    print(base64.b64encode(raw.encode()).decode())
