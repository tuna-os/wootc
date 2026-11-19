"""Behavioral controls for the offline catalog checker and immutable-pin updater.

Run from the repository root:
    python3 -m unittest discover -s app -p catalog_sync_test.py
"""
import copy
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import catalog_sync as catalog


SOURCE = {
    "version": 1,
    "images": [{"name": "Bluefin", "image": "ghcr.io/projectbluefin/bluefin:stable",
                "backend": "ostree", "published": True}],
    "families": [{"name": "Yellowfin", "repository": "ghcr.io/tuna-os/yellowfin",
                  "backend": "ostree", "desktops": ["gnome", "xfce"], "suffixes": ["", "-hwe"]}],
}
POLICY = [{"id": "bluefin", "name": "Local presentation", "bootloader": "grub2",
           "status": "experimental", "mokEnroll": "universalblue", "source": {"image": "Bluefin"}}]
REVISION = "b2564052279b7075c5c2e082413300e208ce98be"


def provenance(raw, revision=REVISION):
    return {"repository": catalog.REPOSITORY, "revision": revision,
            "path": catalog.SOURCE_PATH, "sha256": hashlib.sha256(raw).hexdigest()}


class CatalogResolutionTests(unittest.TestCase):
    def test_source_identity_and_local_support_are_independent(self):
        for published in (True, False):
            source = copy.deepcopy(SOURCE)
            source["images"][0].update(image="ghcr.io/projectbluefin/bluefin:reviewed-next", published=published)
            result = catalog.resolve(source, POLICY)
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0]["imageRef"], "ghcr.io/projectbluefin/bluefin:reviewed-next")
            self.assertEqual(result[0]["status"], "experimental")
            self.assertEqual(result[0]["name"], "Local presentation")
            self.assertEqual(result[0]["mokEnroll"], "universalblue")
            self.assertFalse(result[0]["composeFs"])

    def test_only_reviewed_family_desktop_and_suffix_can_be_selected(self):
        policy = [{"id": "xfce", "name": "Yellowfin", "bootloader": "grub2", "status": "experimental",
                   "source": {"family": "Yellowfin", "desktop": "xfce", "suffix": "-hwe"}}]
        self.assertEqual(catalog.resolve(SOURCE, policy)[0]["imageRef"], "ghcr.io/tuna-os/yellowfin:xfce-hwe")
        for field, value in (("desktop", "unreviewed"), ("suffix", "-unreviewed")):
            changed = copy.deepcopy(policy)
            changed[0]["source"][field] = value
            with self.assertRaisesRegex(ValueError, "unreviewed family tag"):
                catalog.resolve(SOURCE, changed)

    def test_shared_policy_must_not_duplicate_identity_or_backend(self):
        for field, value in (("imageRef", "ghcr.io/projectbluefin/bluefin:other"), ("imageRef", ""), ("composeFs", False)):
            with self.subTest(field=field, value=value):
                policy = copy.deepcopy(POLICY)
                policy[0][field] = value
                with self.assertRaisesRegex(ValueError, "duplicates upstream"):
                    catalog.resolve(SOURCE, policy)
        for ref in ("ghcr.io/projectbluefin/bluefin:stable", "ghcr.io/tuna-os/yellowfin:xfce-hwe"):
            policy = [{"id": "shared", "name": "Shared", "imageRef": ref, "composeFs": False, "bootloader": "grub2"}]
            with self.assertRaisesRegex(ValueError, "must select its shared upstream source"):
                catalog.resolve(SOURCE, policy)

    def test_changed_backend_requires_explicit_wootc_boot_policy_review(self):
        source = copy.deepcopy(SOURCE)
        source["images"][0]["backend"] = "composefs"
        with self.assertRaisesRegex(ValueError, "bootloader conflicts"):
            catalog.resolve(source, POLICY)
        policy = copy.deepcopy(POLICY)
        policy[0]["bootloader"] = "systemd-boot"
        self.assertTrue(catalog.resolve(source, policy)[0]["composeFs"])
        self.assertEqual(catalog.resolve(source, policy)[0]["status"], "experimental")

    def test_unknown_version_and_schema_fields_are_not_silently_consumed(self):
        for modification in ({"version": 2}, {"bootloader": "grub2"}):
            source = copy.deepcopy(SOURCE)
            source.update(modification)
            with self.assertRaises(ValueError):
                catalog.resolve(source, POLICY)

    def test_local_only_policy_remains_explicit(self):
        policy = [{"id": "deck", "name": "Deck", "imageRef": "ghcr.io/ublue-os/bazzite-deck:stable",
                   "composeFs": False, "bootloader": "grub2", "status": "experimental"}]
        self.assertEqual(catalog.resolve(SOURCE, policy)[0], policy[0])


class CatalogCommandTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.data = self.root / "app/data"
        self.data.mkdir(parents=True)
        raw = catalog.render(SOURCE)
        for name, content in {
            "catalog-sources.json": raw,
            "catalog-provenance.json": catalog.render(provenance(raw)),
            "catalog-policy.json": catalog.render(POLICY),
            "images.json": catalog.render(catalog.resolve(SOURCE, POLICY)),
        }.items():
            (self.data / name).write_bytes(content)

    def snapshot(self):
        return {path.name: path.read_bytes() for path in self.data.iterdir()}

    def command(self, *args):
        with redirect_stdout(io.StringIO()):
            return catalog.main(["--root", str(self.root), *args])

    def test_check_is_offline_read_only_and_deterministic(self):
        before = self.snapshot()
        with patch.object(catalog, "urlopen", side_effect=AssertionError("offline check fetched network")):
            self.assertEqual(self.command("--check"), 0)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(catalog.render(catalog.resolve(SOURCE, POLICY)), before["images.json"])

    def test_generated_drift_is_rejected_without_writing(self):
        (self.data / "images.json").write_bytes(b"[]\n")
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "generated images.json drift"):
            self.command("--check")
        self.assertEqual(self.snapshot(), before)

    def test_snapshot_hash_drift_is_rejected(self):
        with (self.data / "catalog-sources.json").open("ab") as output:
            output.write(b"\n")
        with self.assertRaisesRegex(ValueError, "snapshot hash drift"):
            self.command("--check")

    def test_policy_edits_regenerate_only_the_derived_artifact(self):
        policy = copy.deepcopy(POLICY)
        policy[0]["name"] = "Reviewed local name"
        (self.data / "catalog-policy.json").write_bytes(catalog.render(policy))
        before = self.snapshot()
        self.assertEqual(self.command(), 0)
        after = self.snapshot()
        self.assertEqual({key for key in before if before[key] != after[key]}, {"images.json"})
        self.assertEqual(json.loads(after["images.json"])[0]["name"], "Reviewed local name")

    def test_revision_must_be_immutable(self):
        with patch.object(catalog, "urlopen", side_effect=AssertionError("mutable revision fetched")):
            with self.assertRaisesRegex(ValueError, "full immutable commit"):
                self.command("--revision", "main")

    def test_update_preserves_exact_source_bytes_and_records_provenance(self):
        raw = json.dumps(SOURCE, separators=(",", ":")).encode() + b"\n\n"
        revision = "1" * 40
        with patch.object(catalog, "urlopen", return_value=io.BytesIO(raw)) as fetch:
            self.assertEqual(self.command("--revision", revision), 0)
        self.assertEqual(fetch.call_args.args[0],
                         f"https://raw.githubusercontent.com/tuna-os/bootc-migrate/{revision}/catalog/sources.json")
        self.assertEqual((self.data / "catalog-sources.json").read_bytes(), raw)
        self.assertEqual(json.loads((self.data / "catalog-provenance.json").read_bytes()), provenance(raw, revision))
        self.assertEqual(self.command("--check"), 0)

    def test_update_rejects_unsupported_version_and_backend_drift_before_writing(self):
        for change in ("version", "backend"):
            source = copy.deepcopy(SOURCE)
            if change == "version":
                source["version"] = 2
            else:
                source["images"][0]["backend"] = "composefs"
            before = self.snapshot()
            with patch.object(catalog, "urlopen", return_value=io.BytesIO(catalog.render(source))):
                with self.assertRaises(ValueError):
                    self.command("--revision", "2" * 40)
            self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main()
