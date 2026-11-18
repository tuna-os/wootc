#!/usr/bin/env python3
"""Exercise distro adoption in a temporary checkout, including negative gates."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('brand', ROOT / 'packaging/brand.py')
brand = importlib.util.module_from_spec(spec)
spec.loader.exec_module(brand)


class BrandAdoption(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copytree(ROOT / 'app/branding', self.root / 'app/branding')
        (self.root / 'app/data').mkdir()
        shutil.copyfile(ROOT / 'app/data/images.json', self.root / 'app/data/images.json')

    def init(self, *extra):
        return subprocess.run([sys.executable, str(ROOT / 'packaging/brand.py'), '--root', str(self.root),
                               'init', '--id', 'acme', '--name', 'Acme Linux', '--publisher', 'Acme',
                               '--website', 'https://example.com', '--support', 'https://example.com/help',
                               '--winget-id', 'Acme.Installer', '--image-ref', 'registry.example.com/acme:stable',
                               *extra], capture_output=True, text=True)

    def non_utf8_environment(self):
        return {**os.environ, 'LC_ALL': 'C', 'LANG': 'C', 'PYTHONCOERCECLOCALE': '0'}

    def locale_cli(self, *args):
        return subprocess.run(
            [sys.executable, '-X', 'utf8=0', str(ROOT / 'packaging/brand.py'),
             '--root', str(self.root), *args],
            env=self.non_utf8_environment(), capture_output=True)

    def test_publisher_cli_reads_real_unicode_brands_without_locale_decoding(self):
        encoding = subprocess.run(
            [sys.executable, '-X', 'utf8=0', '-c', 'import locale; print(locale.getpreferredencoding(False))'],
            env=self.non_utf8_environment(), capture_output=True, check=True).stdout.decode('ascii').strip()
        # POSIX can force ASCII; Windows uses its system ANSI code page when
        # UTF-8 mode is disabled, matching the actual packaging consumer.
        if os.name == 'posix':
            self.assertNotEqual(encoding.lower().replace('-', ''), 'utf8')
        for brand_id in ('wootc', 'tunaos'):
            with self.subTest(brand=brand_id, encoding=encoding):
                config_bytes = (self.root / f'app/branding/{brand_id}/brand.json').read_bytes()
                self.assertTrue(any(byte > 127 for byte in config_bytes), 'real brand fixture must exercise Unicode')
                result = self.locale_cli('identity', '--brand', brand_id)
                self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8'))
                self.assertEqual(json.loads(result.stdout), {'publisher': 'TunaOS', 'copyright': ''})

    def test_cli_writes_unicode_json_and_updates_utf8_brand_table_without_locale_encoding(self):
        result = self.locale_cli(
            'init', '--id', 'acme', '--name', 'Acme Linux', '--publisher', 'Acme',
            '--website', 'https://example.com', '--support', 'https://example.com/help',
            '--winget-id', 'Acme.Installer', '--image-ref', 'registry.example.com/acme:stable', '--self-owned')
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8'))
        config_bytes = (self.root / 'app/branding/acme/brand.json').read_bytes()
        self.assertIn('🐧'.encode('utf-8'), config_bytes)
        self.assertEqual(json.loads(config_bytes)['logoEmoji'], '🐧')
        images = json.loads((self.root / 'app/branding/acme/images.json').read_bytes())
        self.assertEqual(images[0]['emoji'], '🐧')
        table = (self.root / 'app/branding/README.md').read_bytes().decode('utf-8')
        self.assertIn('| `acme` | Acme | blessed |', table)
        validated = self.locale_cli('validate', '--brand', 'acme')
        self.assertEqual(validated.returncode, 0, validated.stderr.decode('utf-8'))

    def test_owner_can_adopt_without_core_code_changes(self):
        result = self.init('--self-owned')
        self.assertEqual(result.returncode, 0, result.stderr)
        config = brand.validate(self.root, 'acme')
        self.assertEqual(config['publisher'], 'Acme')
        self.assertEqual(config['catalog'], ['acme'])
        images = brand.read(self.root / 'app/branding/acme/images.json')
        self.assertEqual(images[0]['status'], 'experimental')
        self.assertIn('acme', brand.ownership(self.root)['selfOwnedBrands'])
        self.assertIn('| `acme` | Acme | blessed |', (self.root / 'app/branding/README.md').read_text())
        self.assertNotEqual(self.init('--self-owned').returncode, 0, 'must not overwrite an existing brand')

    def test_no_permission_is_invented_for_a_third_party(self):
        self.assertEqual(self.init().returncode, 0)
        record = brand.read(self.root / 'app/branding/acme/blessing.json')
        self.assertEqual(record['status'], 'pending')
        self.assertFalse(record['winget']['identifierAgreed'])

    def test_bad_id_and_non_https_link_do_not_create_a_brand(self):
        for args in [('--id', '../escape'), ('--support', 'javascript:alert(1)')]:
            with self.subTest(args=args):
                self.assertNotEqual(self.init(*args).returncode, 0)
                self.assertFalse((self.root / 'app/branding/acme').exists())

    def test_validation_rejects_mispackaging(self):
        self.assertEqual(self.init('--self-owned').returncode, 0)
        path = self.root / 'app/branding/acme/brand.json'
        good = brand.read(path)
        for field, value in [('exeName', '../evil'), ('exeName', 'CON'), ('exeName', 'wootc'),
                             ('supportURL', 'file:///etc/passwd'), ('defaultImage', 'absent'),
                             ('catalog', ['absent']), ('accent', 'red'), ('unknownOption', True)]:
            with self.subTest(field=field, value=value):
                brand.write(path, {**good, field: value})
                with self.assertRaises(ValueError):
                    brand.validate(self.root, 'acme')
        brand.write(path, good)
        record_path = path.with_name('blessing.json')
        record = brand.read(record_path)
        record['decisions']['distributeExe'] = 'no'
        brand.write(record_path, record)
        with self.assertRaises(ValueError):
            brand.validate(self.root, 'acme')


if __name__ == '__main__':
    unittest.main()
