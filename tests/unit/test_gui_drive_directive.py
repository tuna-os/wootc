#!/usr/bin/env python3
"""The harness's GUI install directive, per driven frontend."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / 'tests/e2e/gui-drive-directive.py'
RUNNER = ROOT / 'tests/e2e/run-e2e.sh'
FIXTURES = ROOT / 'tests/unit/fixtures/e2e-drive'
spec = importlib.util.spec_from_file_location('drive_directive', BUILDER)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
RUN = '20261015-native-fixture'
DIRECTIVE = '0123456789abcdef0123456789abcdef'
IMAGE = 'ghcr.io/tuna-os/yellowfin:gnome'


def build(*args):
    return subprocess.run(['python3', str(BUILDER), *args], text=True, capture_output=True)


class GuiDriveDirectiveTests(unittest.TestCase):
    def test_wails_directive_is_unchanged(self):
        # The construction run-e2e.sh used inline before the native shell.
        value = dict(schemaVersion=1, runId=RUN, directiveId=DIRECTIVE,
                     action='install', image=IMAGE, username='wootc',
                     password='wootc-e2e-pass', hostname='wootc-test')
        legacy = base64.b64encode(json.dumps(value, separators=(',', ':')).encode()).decode()
        result = build('wails', RUN, DIRECTIVE, IMAGE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), legacy)
        self.assertNotIn('storageId', module.install_directive('wails', RUN, DIRECTIVE, IMAGE))

    def test_native_directive_is_the_shared_golden(self):
        # shell/Wootc.Shell.Tests and app/e2e_drive_receipt_test.go read these bytes.
        result = build('native', RUN, DIRECTIVE, IMAGE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(base64.b64decode(result.stdout.strip()).decode(),
                         (FIXTURES / 'directive-install.json').read_text())
        self.assertEqual(json.loads(module.install_directive('native', RUN, DIRECTIVE, IMAGE))['storageId'], 'C:')

    def test_refuses_unknown_frontends_and_identities(self):
        for args in (('gtk', RUN, DIRECTIVE, IMAGE), ('native', '', DIRECTIVE, IMAGE),
                     ('wails', RUN, DIRECTIVE.upper(), IMAGE), ('native', RUN, DIRECTIVE, ''),
                     ('native', 'r' * 129, DIRECTIVE, IMAGE), ('wails',)):
            result = build(*args)
            self.assertEqual(result.returncode, 2, args)
            self.assertEqual(result.stdout, '')
        # A long run identity still drives the Wails app as it always did.
        self.assertEqual(build('wails', 'r' * 129, DIRECTIVE, IMAGE).returncode, 0)

    def test_runner_writes_the_selected_frontends_directive(self):
        source = RUNNER.read_text()
        self.assertIn('GUI_FRONTEND="${WOOTC_E2E_GUI_FRONTEND:-wails}"', source)
        self.assertIn('python3 "$SCRIPT_DIR/gui-drive-directive.py" "$GUI_FRONTEND" "$RUN_ID" "$drive_directive_id" "$IMAGE_REF"', source)
        self.assertNotIn("<<'PYDRIVE'", source)

    def test_runner_refuses_a_native_run_it_cannot_launch(self):
        # Driving the Wails app while recording a native run would be a green
        # built on a proxy. Without a valid native package (or without the GUI
        # path at all) the refusal comes before any VM work.
        if (ROOT / 'tests/e2e/wootc-files/native-shell/native-package.json').exists():
            self.skipTest('a native package is staged in this checkout')
        for value, args, words in (('native', ['--gui-install'], 'no valid native shell package'),
                                   ('native', [], 'needs --gui-install'),
                                   ('gtk', ['--gui-install'], 'must be wails or native')):
            env = dict(os.environ, WOOTC_E2E_GUI_FRONTEND=value)
            result = subprocess.run(['bash', str(RUNNER), *args], env=env, text=True,
                                    capture_output=True, timeout=60)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(words, result.stderr)

    def test_runner_no_longer_refuses_native_outright(self):
        self.assertNotIn('cannot launch the native shell', RUNNER.read_text())


if __name__ == '__main__':
    unittest.main()
