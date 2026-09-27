import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('receipt', Path(__file__).parents[1] / 'e2e/verify-control-panel-receipt.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.directive = {'action': 'verify-installed-boot', 'runId': 'run-current', 'nonce': 'fresh',
                          'expected': {'kernel': '6.12', 'sourceImageRef': 'image@sha256:observed',
                                       'boundFolders': 3, 'matchedUsers': 1}}
        self.receipt = {'action': 'verify-installed-boot', 'runId': 'run-current', 'nonce': 'fresh',
                        'passed': True, 'errors': [], 'observed': {
                            'kernel': '6.12', 'sourceImageRef': 'image@sha256:observed',
                            'boundFolders': '3', 'matchedUsers': '1', 'heading': 'TunaOS boot verified',
                            'summary': 'Linux 6.12 · image@sha256:observed · 3 folders connected for 1 users'}}
        self.state = {'screen': 'control', 'installedBootVerification': self.receipt}

    def test_current_visible_fields(self):
        self.assertEqual(module.verify(self.directive, self.state), self.receipt)

    def test_no_receipt_and_stale_or_unrendered_receipt(self):
        for change in ({'installedBootVerification': None}, {'screen': 'launchpad'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                module.verify(self.directive, {**self.state, **change})
        for change in ({'runId': 'previous'}, {'nonce': 'old'}, {'passed': False}, {'errors': ['hidden']}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                module.verify(self.directive, {**self.state, 'installedBootVerification': {**self.receipt, **change}})

    def test_passed_flag_cannot_hide_wrong_rendered_fields(self):
        for field in self.receipt['observed']:
            state = copy.deepcopy(self.state)
            state['installedBootVerification']['observed'][field] = 'wrong'
            with self.subTest(field=field), self.assertRaises(ValueError):
                module.verify(self.directive, state)


if __name__ == '__main__':
    unittest.main()
