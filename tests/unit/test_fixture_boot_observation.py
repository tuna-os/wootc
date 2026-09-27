import importlib.util
import json
from pathlib import Path
import unittest

source = Path(__file__).resolve().parents[1] / 'e2e/verify-fixture-boot-observation.py'
spec = importlib.util.spec_from_file_location('boot_observation', source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FixtureBootObservationTests(unittest.TestCase):
    def record(self, boot='134350000000000000'):
        return json.dumps({'schemaVersion': 1, 'os': 'Windows_NT', 'bootId': boot}).encode()

    def test_actual_observations_require_same_boot_during_detach_and_new_boot_after(self):
        first, later = self.record(), self.record('134350000000000001')
        self.assertEqual(module.compare(first, first, 'same', 'run-1')['observation'], 'same')
        self.assertEqual(module.compare(first, later, 'changed', 'run-1')['observation'], 'changed')
        for before, after, mode in [(first, later, 'same'), (first, first, 'changed')]:
            with self.assertRaises(ValueError):
                module.compare(before, after, mode, 'run-1')

    def test_missing_wrong_duplicate_and_unbounded_observations_cannot_assert_identity(self):
        cases = [b'{}', b'null', b'', b'x' * 4097,
                 b'{"schemaVersion":true,"os":"Windows_NT","bootId":"134350000000000000"}',
                 b'{"schemaVersion":1,"os":"Linux","bootId":"134350000000000000"}',
                 b'{"schemaVersion":1,"os":"Windows_NT","bootId":134350000000000000}',
                 b'{"schemaVersion":1,"os":"Windows_NT","bootId":"134350000000000000","bootId":"134350000000000001"}',
                 b'{"schemaVersion":1,"os":"Windows_NT","bootId":"134350000000000001","bootId":"134350000000000000"}']
        for case in cases:
            with self.subTest(case=case):
                with self.assertRaises((ValueError, UnicodeError)):
                    module.compare(self.record(), case, 'same', 'run-1')


if __name__ == '__main__':
    unittest.main()
