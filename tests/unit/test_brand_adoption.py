#!/usr/bin/env python3
"""Exercise distro adoption in a temporary checkout, including negative gates."""
import importlib.util
import json
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
