"""Exercise production stamp derivation on PE certificate-table bytes, not workflow text."""
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'shell/packaging/release-metadata.py'
SPEC = importlib.util.spec_from_file_location('native_release_metadata', SCRIPT)
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
SHA = 'a' * 40
KEY = 'b' * 64


class NativeReleaseMetadata(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.fixture.name)
        cls.certificates = {}
        for generation, name in [('2011', 'Microsoft Corporation UEFI CA 2011'), ('2023', 'Microsoft UEFI CA 2023')]:
            cert = cls.directory / f'{generation}.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                            '-keyout', str(cls.directory / f'{generation}.key'), '-out', str(cert),
                            '-subj', f'/CN={name}', '-days', '1'], check=True, capture_output=True)
            cls.certificates[generation] = subprocess.run(
                ['openssl', 'crl2pkcs7', '-nocrl', '-certfile', str(cert), '-outform', 'DER'],
                check=True, capture_output=True).stdout

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.assets = Path(self.work.name)
        (self.assets / 'artifact-public-key.hex').write_text(KEY + '\n')
        self.write_shim('2011', '2023')

    def write_shim(self, *generations):
        # A synthetic PE certificate table tests extraction and provenance only;
        # it is not an executable shim or firmware signature acceptance proof.
        image = bytearray(512)
        image[:2] = b'MZ'
        struct.pack_into('<I', image, 0x3c, 64)
        image[64:68] = b'PE\0\0'
        struct.pack_into('<H', image, 84, 240)
        struct.pack_into('<H', image, 88, 0x20b)
        table = bytearray()
        for generation in generations:
            certificate = self.certificates[generation]
            record = struct.pack('<IHH', len(certificate) + 8, 0x200, 2) + certificate
            table.extend(record + b'\0' * (-len(record) % 8))
        struct.pack_into('<II', image, 88 + 112 + 4 * 8, len(image), len(table))
        (self.assets / 'shimx64.efi').write_bytes(image + table)

    def derive(self, **changes):
        args = dict(directory=self.assets, tag='v1.2.3', source_commit=SHA,
                    release_commit=SHA, repository='tuna-os/wootc')
        args.update(changes)
        return release.metadata(**args)

    def test_exact_released_binary_supplies_dual_stamp_and_release_provenance(self):
        result = self.derive()
        flags = result['engine_ldflags'].split()
        for stamp in [f'main.artifactPublicKey={KEY}', 'main.releaseTag=v1.2.3',
                      'main.shimAuthorities=2011,2023',
                      'main.releasesBaseURL=https://github.com/tuna-os/wootc/releases/']:
            self.assertIn(stamp, flags)
        self.assertEqual(result['shim_authorities'], '2011,2023')
        self.assertEqual(result['production'], 'true')

    def test_stamp_changes_with_released_binary_not_untrusted_authorities_json(self):
        (self.assets / 'shim-authorities.json').write_text('{"shimx64.efi":["2011"]}')
        self.write_shim('2023')
        self.assertIn('main.shimAuthorities=2023', self.derive()['engine_ldflags'])
        self.assertNotIn('2011', self.derive()['shim_authorities'])

    def test_missing_2023_or_malformed_or_missing_released_shim_refuses(self):
        for content in [None, b'not a PE image']:
            with self.subTest(content=content):
                path = self.assets / 'shimx64.efi'
                if content is None:
                    path.unlink()
                else:
                    path.write_bytes(content)
                with self.assertRaises((OSError, release.shim.PEError)):
                    self.derive()
        self.write_shim('2011')
        with self.assertRaisesRegex(ValueError, '2023'):
            self.derive()

    def test_unrelated_source_commit_and_unsafe_tag_repository_or_key_refuse(self):
        for changes in [{'release_commit': 'c' * 40}, {'tag': '../other'}, {'repository': 'other/repo\nflags'}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.derive(**changes)
        (self.assets / 'artifact-public-key.hex').write_text('missing')
        with self.assertRaisesRegex(ValueError, '32-byte hex'):
            self.derive()

    def test_cli_emits_only_validated_github_build_inputs_and_failure_emits_nothing(self):
        output = self.assets / 'outputs'
        command = [sys.executable, str(SCRIPT), '--directory', str(self.assets), '--tag', 'v1.2.3',
                   '--source-commit', SHA, '--release-commit', SHA, '--repository', 'tuna-os/wootc',
                   '--github-output', str(output)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        values = dict(line.split('=', 1) for line in output.read_text().splitlines())
        self.assertEqual(values, self.derive())
        output.unlink()
        (self.assets / 'artifact-public-key.hex').unlink()
        failed = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
