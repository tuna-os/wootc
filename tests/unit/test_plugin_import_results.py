#!/usr/bin/env python3
"""Execute all real wrappers with absent, failing and unverified importers."""
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPERS = {'browsers':'wootc-import-browser', 'office':'wootc-office-bridge',
           'identity':'wootc-identity', 'wsl':'wootc-wsl-bridge',
           'steam':'wootc-steam-bridge', 'look':'wootc-apply-look', 'wifi':'wootc-wifi-bridge'}
STRUCTURED = {'office', 'steam', 'wsl'}


class PluginResults(unittest.TestCase):
    def test_real_wrappers_never_invent_migrated_items(self):
        for plugin, helper in HELPERS.items():
            for mode in ('missing', 'failed', 'returned', 'no-user'):
                if mode == 'no-user' and plugin not in ('browsers','office','identity','wsl'):
                    continue
                with self.subTest(plugin=plugin, mode=mode), tempfile.TemporaryDirectory() as temp:
                    base = Path(temp)
                    bins = base/'bin'; bins.mkdir()
                    for name in ('python3','dirname'):
                        (bins/name).symlink_to(shutil.which(name))
                    marker = base/'invoked'
                    if mode != 'missing':
                        script = bins/helper
                        check = 'import json,os; r=json.load(open(os.environ["WOOTC_STATE_DIR"]+"/status.json")); assert r["status"]!="success" and r["migrated"]==[]'
                        script.write_text("#!/bin/sh\npython3 -c '" + check + "' || exit 91\n: > \"$TEST_MARKER\"\nexit " + ('7' if mode=='failed' else '0') + "\n")
                        script.chmod(0o755)
                    state = base/'state'; state.mkdir()
                    (state/'status.json').write_text('{"status":"success","migrated":["stale"]}')
                    env = {**os.environ, 'PATH':str(bins), 'WOOTC_STATE_DIR':str(state),
                           'WOOTC_WIN_USER':'' if mode=='no-user' else 'Alice', 'WOOTC_LINUX_USER':'alice',
                           'TEST_MARKER':str(marker)}
                    result = subprocess.run([shutil.which('bash'),str(ROOT/'payload/migration/plugins.d'/plugin/'bin/import')],
                                            env=env,capture_output=True,text=True)
                    record = json.loads((state/'status.json').read_text())
                    self.assertEqual(record['migrated'], [])
                    self.assertFalse(record['verified'])
                    self.assertNotEqual(record['status'], 'success')
                    returned_legacy = mode == 'returned' and plugin not in STRUCTURED
                    self.assertEqual(record['status'], 'partial' if returned_legacy else 'failed')
                    self.assertEqual(result.returncode == 0, returned_legacy, result.stderr)
                    self.assertEqual(marker.exists(), mode in ('failed','returned'))
                    self.assertEqual(list(state.glob('.status-*')), [])

    def test_structured_results_retain_actual_item_outcomes_and_refuse_false_success(self):
        cases = [
            ({'status': 'success', 'migrated': ['copied'], 'alreadyPresent': [], 'preserved': [], 'failed': []}, 0, 'success'),
            ({'status': 'partial', 'migrated': ['copied'], 'alreadyPresent': [], 'preserved': ['Linux edit'], 'failed': []}, 0, 'partial'),
            ({'status': 'failed', 'migrated': ['copied'], 'alreadyPresent': [], 'preserved': [], 'failed': [{'error': 'disk full'}]}, 1, 'failed'),
            ({'status': 'failed', 'migrated': [], 'alreadyPresent': [], 'preserved': [], 'failed': []}, 1, 'failed'),
            ({'status': 'success', 'migrated': [], 'alreadyPresent': [], 'preserved': [], 'failed': []}, 1, 'failed'),
        ]
        for plugin in STRUCTURED:
            for evidence, expected_rc, expected_status in cases:
                with self.subTest(plugin=plugin, evidence=evidence), tempfile.TemporaryDirectory() as temp:
                    base = Path(temp)
                    bins = base / 'bin'; bins.mkdir()
                    for name in ('python3', 'dirname'):
                        (bins / name).symlink_to(shutil.which(name))
                    helper = bins / HELPERS[plugin]
                    helper.write_text('#!/bin/sh\nprintf \'%s\\n\' ' + shlex.quote(json.dumps(evidence)) + '\n')
                    helper.chmod(0o755)
                    state = base / 'state'
                    env = {**os.environ, 'PATH': str(bins), 'WOOTC_STATE_DIR': str(state),
                           'WOOTC_WIN_USER': 'Alice', 'WOOTC_LINUX_USER': 'fixture'}
                    completed = subprocess.run([shutil.which('bash'), str(ROOT / 'payload/migration/plugins.d' / plugin / 'bin/import')],
                                               capture_output=True, text=True, env=env)
                    self.assertEqual(completed.returncode, expected_rc, completed.stderr)
                    record = json.loads((state / 'status.json').read_text())
                    self.assertEqual(record['status'], expected_status)
                    self.assertFalse(record['verified'])
                    self.assertEqual(record['migrated'], evidence['migrated'])
                    self.assertEqual(record['preserved'], evidence['preserved'])

    def test_result_directory_symlink_is_refused_before_running_helper(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            outside = base / 'outside'; outside.mkdir()
            canary = outside / 'status.json'
            canary.write_text('native original')
            linked = base / 'state'; linked.symlink_to(outside, target_is_directory=True)
            env = {**os.environ, 'WOOTC_STATE_DIR': str(linked), 'WOOTC_WIN_USER': 'Alice',
                   'WOOTC_LINUX_USER': 'fixture'}
            completed = subprocess.run([shutil.which('bash'), str(ROOT / 'payload/migration/plugins.d/office/bin/import')],
                                       capture_output=True, text=True, env=env)
            self.assertNotEqual(completed.returncode, 0)
            self.assertEqual(canary.read_text(), 'native original')
            self.assertTrue(linked.is_symlink())



if __name__ == '__main__':
    unittest.main()
