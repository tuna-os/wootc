#!/usr/bin/env python3
"""Execute all real wrappers with absent, failing and unverified importers."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPERS = {'browsers':'wootc-import-browser', 'office':'wootc-office-bridge',
           'identity':'wootc-identity', 'wsl':'wootc-wsl-bridge',
           'steam':'wootc-steam-bridge', 'look':'wootc-apply-look', 'wifi':'wootc-wifi-bridge'}


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
                    self.assertEqual(record['status'], 'partial' if mode=='returned' else 'failed')
                    self.assertEqual(result.returncode==0, mode=='returned', result.stderr)
                    self.assertEqual(marker.exists(), mode in ('failed','returned'))
                    self.assertEqual(list(state.glob('.status-*')), [])


if __name__ == '__main__':
    unittest.main()
