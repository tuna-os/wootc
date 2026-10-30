import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).parents[2]
spec = importlib.util.spec_from_file_location('catalog_drift', ROOT / 'tools/catalog/check-drift.py')
catalog_drift = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog_drift)


class CatalogDriftTests(unittest.TestCase):
    def source(self):
        return {
            'version': 1,
            'images': [
                {
                    'name': 'Dakota stable',
                    'image': 'ghcr.io/projectbluefin/dakota:stable',
                    'backend': 'composefs',
                    'published': True,
                    'bootloader': 'systemd-boot',
                },
            ],
            'families': [
                {
                    'name': 'Yellowfin',
                    'repository': 'ghcr.io/tuna-os/yellowfin',
                    'backend': 'ostree',
                    'desktops': ['gnome'],
                    'suffixes': ['', '-nvidia'],
                    'bootloader': 'grub2',
                },
            ],
        }

    def test_shared_primary_and_family_images_agree(self):
        catalog = [
            {
                'id': 'dakota',
                'imageRef': 'ghcr.io/projectbluefin/dakota:stable',
                'composeFs': True,
                'bootloader': 'systemd-boot',
            },
            {
                'id': 'yellowfin-gnome',
                'imageRef': 'ghcr.io/tuna-os/yellowfin:gnome',
                'composeFs': False,
                'bootloader': 'grub2',
            },
            {
                'id': 'wootc-only',
                'imageRef': 'ghcr.io/example/wootc-only:stable',
                'composeFs': False,
                'bootloader': 'grub2',
            },
        ]

        matched, errors = catalog_drift.compare_catalogs(catalog, self.source())

        self.assertEqual(matched, 2)
        self.assertEqual(errors, [])

    def test_each_shared_contract_difference_is_reported(self):
        catalog = [
            {
                'id': 'dakota',
                'imageRef': 'ghcr.io/projectbluefin/dakota:latest',
                'composeFs': False,
                'bootloader': 'grub2',
            },
        ]

        matched, errors = catalog_drift.compare_catalogs(catalog, self.source())

        self.assertEqual(matched, 1)
        self.assertEqual(len(errors), 3)
        self.assertTrue(any('imageRef' in error and 'dakota:stable' in error for error in errors))
        self.assertTrue(any('composeFs' in error and "'composefs'" in error for error in errors))
        self.assertTrue(any('bootloader' in error and 'systemd-boot' in error for error in errors))

    def test_source_without_shared_identity_is_rejected(self):
        catalog = [
            {
                'id': 'wootc-only',
                'imageRef': 'ghcr.io/example/wootc-only:stable',
                'composeFs': False,
            },
        ]

        with self.assertRaisesRegex(ValueError, 'no shared image identities'):
            catalog_drift.compare_catalogs(catalog, self.source())


if __name__ == '__main__':
    unittest.main()
