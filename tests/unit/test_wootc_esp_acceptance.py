"""Fixture-only acceptance counterexamples; no firmware claim."""
import copy
import base64
import hashlib
import os
from pathlib import Path
import runpy
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
accept = runpy.run_path(str(ROOT/'tests/e2e/esp-chain/accept.py'))['validate']
scratch = runpy.run_path(str(ROOT/'tests/e2e/esp-chain/scratch.py'))['provision']


class AcceptanceTests(unittest.TestCase):
    def setUp(self):
        files = ('shimx64.efi', 'grubx64.efi', 'mmx64.efi')
        old = dict.fromkeys(files, '1'*64)
        new = dict.fromkeys(files, '2'*64)
        identity = {'hostUuid': '1234567890ABCDEF', 'hostEspUuid': 'AAAA-BBBB',
                    'rootDiskPath': '/wootc/disks/root.disk', 'loaderVendor': 'debian',
                    'deploymentKind': 'classic', 'bootCurrent': {'bootNumber': 5, 'loaderPath': '\\EFI\\debian\\shimx64.efi',
                    'espPartitionGuid': 'a'*36}, 'rootFsUuid': 'fixture-root'}
        plan = {'schemaVersion': 1, 'scratchId': 'a'*32, 'vmUuid': 'fixture-vm', 'oldHashes': old, 'newHashes': new, 'identity': identity}
        raw = b'\x07\0\0\0sbat,1,2024010100\ngrub,1\n\0'
        encoded = base64.b64encode(raw).decode()
        plan['sbatTransition'] = {'oldVariableBase64': encoded, 'newVariableBase64': encoded, 'newShimSha256': new['shimx64.efi']}
        captures = []
        for index, hashes in enumerate((old, new, new)):
            boot = dict(identity, bootId='00000000-0000-0000-0000-'+str(index).zfill(12), secureBoot=True, rootKind='loop')
            captures.append({'vmUuid': 'fixture-vm', 'observation': boot, 'trioHashes': hashes, 'sourceHashes': hashes,
                             'signatureProof': {'verified': True}, 'failedUnits': [], 'pendingJournal': False,
                             'receipt': {'ownedManifestSha256': 'fixture', 'preparedBootId': boot['bootId'], 'sourceEFI': {'version': 'old' if not index else 'new'}}, 'foreignFiles': {'EFI/Microsoft/a': 'kept'},
                             'firmwareObservationSource': 'current-boot-efivars', 'archiveHashes': old if index else None, 'firmwareTrustHashes': dict(dict.fromkeys(('SecureBoot', 'SetupMode', 'db', 'dbx', 'MokListXRT'), '3'*64), SbatLevelRT=hashlib.sha256(raw).hexdigest()), 'firmwareSbatVariableBase64': encoded, 'firmwareSbatPolicy': {'sbat': 1, 'grub': 1},
                             'upgradeSignatureProof': {'verified': True, 'current': old, 'candidate': new} if index else None,
                             'sourceFacts': {'sourceKind': 'classic', 'version': 'old' if not index else 'new', 'timestamp': str(index)}})
        windows = {'vmUuid': 'fixture-vm', 'scratchId': plan['scratchId'], 'os': 'Windows_NT', 'hostUuid': identity['hostUuid'], 'afterLinuxBootId': '00000000-0000-0000-0000-000000000002'}
        windows['bitlocker'] = dict.fromkeys(('host', 'system'), {'volumeStatus': 'FullyDecrypted', 'protectionStatus': 'Off', 'encryptionPercentage': 0})
        plan['firmwareTrustHashes'] = dict(captures[0]['firmwareTrustHashes'])
        self.args = [plan, *captures, windows]

    def test_complete_observation_contract(self):
        result = accept(*self.args)
        self.assertTrue(result['observationsMatch'])
        self.assertFalse(result['firmwareAcceptance'])
        self.assertFalse(result['chronologyVerified'])

    def test_unplanned_sbat_ratchet_refused(self):
        for capture in self.args[2:4]:
            capture['firmwareTrustHashes']['SbatLevelRT'] = 'unbound-arbitrary-bytes'
            capture['firmwareSbatPolicy'] = {'sbat': 1, 'grub': 65535, 'unplanned-component': 12}
        with self.assertRaises(ValueError):
            accept(*self.args)

    def test_sbat_bytes_hash_policy_and_plan_are_bound(self):
        for mutation in ('hash', 'bytes', 'policy', 'missing-trust', 'shim'):
            args = copy.deepcopy(self.args)
            if mutation == 'hash': args[2]['firmwareTrustHashes']['SbatLevelRT'] = '4'*64
            elif mutation == 'bytes': args[2]['firmwareSbatVariableBase64'] = base64.b64encode(b'\x07\0\0\0sbat,1\ngrub,2\n\0').decode()
            elif mutation == 'policy': args[2]['firmwareSbatPolicy']['grub'] = 2
            elif mutation == 'missing-trust': del args[1]['firmwareTrustHashes']['dbx']
            else: args[0]['sbatTransition']['newShimSha256'] = '4'*64
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                accept(*args)

    def test_unknown_truncated_or_malformed_policy_refused(self):
        for raw in (b'\x06\0', b'\x08\0\0\0sbat,1\n', b'\x06\0\0\0sbat,1\ngrub,1\ngrub,2\n', b'\x06\0\0\0sbat,1\n\0\0', b'\x06\0\0\0sbat,1\ngrub,65536\n'):
            args = copy.deepcopy(self.args)
            args[2]['firmwareSbatVariableBase64'] = base64.b64encode(raw).decode()
            args[2]['firmwareTrustHashes']['SbatLevelRT'] = hashlib.sha256(raw).hexdigest()
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                accept(*args)

    def test_expected_policy_alone_cannot_satisfy_runtime_observation(self):
        self.args[0]['initialFirmwarePolicy'] = {'mode': 'planned-old-shim-bootstrap', 'oldShimSha256': self.args[0]['oldHashes']['shimx64.efi'], 'expectedVariableBase64': self.args[0]['sbatTransition']['oldVariableBase64'], 'currentBootObserved': False}
        self.assertTrue(accept(*self.args)['observationsMatch'])
        self.args[1]['firmwareObservationSource'] = 'old-shim-embedded-policy'
        with self.assertRaisesRegex(ValueError, 'current-boot firmware observation absent'):
            accept(*self.args)

    def test_partial_component_upgrade_keeps_complete_trio(self):
        for data in self.args[:4]:
            if 'newHashes' in data:
                data['newHashes']['shimx64.efi'] = data['oldHashes']['shimx64.efi']
            if data.get('trioHashes') == self.args[0]['newHashes']:
                data['sourceHashes']['shimx64.efi'] = self.args[0]['oldHashes']['shimx64.efi']
        self.args[0]['sbatTransition']['newShimSha256'] = self.args[0]['newHashes']['shimx64.efi']
        self.assertTrue(accept(*self.args)['observationsMatch'])
        self.args[0]['requireAllComponentsChanged'] = True
        with self.assertRaises(ValueError):
            accept(*self.args)

    def test_underlying_observations_required(self):
        mutations = [
            (2, ('observation', 'bootId'), '00000000-0000-0000-0000-000000000000'),
            (2, ('observation', 'secureBoot'), False),
            (2, ('observation', 'hostUuid'), 'other'),
            (2, ('observation', 'bootCurrent'), {}),
            (2, ('sourceHashes',), self.args[0]['oldHashes']),
            (2, ('archiveHashes',), None),
            (2, ('signatureProof', 'verified'), False),
            (2, ('upgradeSignatureProof', 'candidate'), self.args[0]['oldHashes']),
            (3, ('firmwareTrustHashes',), {}),
            (3, ('firmwareSbatPolicy',), {'sbat': 1, 'grub': 0}),
            (2, ('pendingJournal',), True),
            (2, ('receipt', 'preparedBootId'), 'stale'),
            (2, ('receipt', 'sourceEFI', 'version'), 'stale'),
            (3, ('foreignFiles',), {}),
            (3, ('sourceFacts',), self.args[1]['sourceFacts']),
            (4, ('os',), 'Linux'),
            (3, ('vmUuid',), 'foreign-vm'),
            (4, ('vmUuid',), 'foreign-vm'),
            (4, ('afterLinuxBootId',), 'stale'),
            (4, ('hostUuid',), 'other'),
        ]
        for index, path, value in mutations:
            with self.subTest(path=path):
                args = copy.deepcopy(self.args)
                target = args[index]
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                with self.assertRaises(ValueError):
                    accept(*args)

    def test_scratch_hash_and_private_ownership(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = root/'baseline.qcow2'
            baseline.write_bytes(b'fixture only')
            expected = hashlib.sha256(baseline.read_bytes()).hexdigest()
            calls = []
            def run(args, **kwargs):
                calls.append(args)
                if args[1] == 'create':
                    Path(args[-1]).write_bytes(b'overlay fixture')
            first = scratch(root, baseline, expected, run)
            second = scratch(root, baseline, expected, run)
            self.assertNotEqual(first['scratchId'], second['scratchId'])
            self.assertEqual(baseline.read_bytes(), b'fixture only')
            self.assertTrue(all(args[0] == 'qemu-img' for args in calls))
            with self.assertRaises(ValueError):
                scratch(root, baseline, '0'*64, run)
            self.assertEqual(len(calls), 4)
            root.chmod(0o755)
            with self.assertRaises(ValueError):
                scratch(root, baseline, expected, run)


if __name__ == '__main__':
    unittest.main()
