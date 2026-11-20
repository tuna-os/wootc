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
PROVEN = {"id": "yellowfin-xfce", "name": "Yellowfin", "bootloader": "grub2", "status": "green",
          "source": {"family": "Yellowfin", "desktop": "xfce", "suffix": ""}, "evidence": {"run": 123}}


def target(variant, flavor, platform="linux/amd64", available=True, scope="generic", facts=None, tag=None):
    tag = flavor if tag is None else tag
    return {"targetKey": f"{variant}:{flavor}:{platform}",
            "target": {"variant": variant, "flavor": flavor, "platform": platform, "hardwareScope": scope},
            "availability": {"available": available},
            "publication": {"ref": f"ghcr.io/tuna-os/{variant}:{tag}",
                            "repository": f"ghcr.io/tuna-os/{variant}", "tag": tag},
            "facts": {"hasSdBoot": False, "repoFamily": "fedora", **(facts or {})}}


SNAPSHOT = {"kind": "catalog-snapshot", "schemaVersion": 1, "generatedAt": "2026-11-20T00:00:00Z",
            "snapshotDigest": "sha256:" + "a" * 64,
            "targets": [target("yellowfin", "xfce"), target("yellowfin", "gnome")]}


def provenance(raw, revision=REVISION, snapshot_raw=None):
    snapshot_raw = catalog.render(SNAPSHOT) if snapshot_raw is None else snapshot_raw
    return {"repository": catalog.REPOSITORY, "revision": revision,
            "path": catalog.SOURCE_PATH, "sha256": hashlib.sha256(raw).hexdigest(),
            "tunaosSnapshot": catalog.snapshot_pin(snapshot_raw)}


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


class SnapshotCandidateTests(unittest.TestCase):
    def refs(self, *targets):
        snapshot = dict(SNAPSHOT, targets=list(targets))
        return [candidate["imageRef"] for candidate in catalog.snapshot_candidates(snapshot)]

    def test_only_generic_available_amd64_flavors_are_candidates(self):
        hardware = [target("bonito", flavor) for flavor in (
            "gnome-nvidia", "base-hwe", "kde-cachyos", "gnome-asahi", "gnome-x13s", "gnome-t2", "gnome-zfs",
            "kde-nvidia-hwe")]
        others = [target("bonito", "kde", platform="linux/arm64"), target("bonito", "niri", available=False),
                  target("bonito", "cosmic", scope="apple-t2")]
        self.assertEqual(self.refs(*hardware, *others, target("bonito", "gnome"),
                                   target("bonito-rawhide", "gnome", tag="gnome-rawhide")),
                         ["ghcr.io/tuna-os/bonito:gnome", "ghcr.io/tuna-os/bonito-rawhide:gnome-rawhide"])

    def test_publication_ref_is_the_image_identity(self):
        bad = target("bonito", "gnome")
        bad["publication"]["ref"] = "ghcr.io/tuna-os/bonito:kde"
        with self.assertRaisesRegex(ValueError, "invalid publication"):
            self.refs(bad)
        foreign = target("bonito", "gnome")
        foreign["publication"] = {"ref": "ghcr.io/other/bonito:gnome", "repository": "ghcr.io/other/bonito",
                                  "tag": "gnome"}
        with self.assertRaisesRegex(ValueError, "invalid publication"):
            self.refs(foreign)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.refs(target("bonito", "gnome"), target("bonito", "gnome"))

    def test_backend_comes_only_from_the_observed_fact(self):
        self.assertIsNone(catalog.snapshot_backend({"hasSdBoot": True, "repoFamily": "arch"}))
        self.assertIsNone(catalog.snapshot_backend({"hasSdBoot": False, "repoFamily": "fedora"}))
        for value in ("ostree", "composefs"):
            self.assertEqual(catalog.snapshot_backend({"hasSdBoot": False, catalog.SNAPSHOT_BACKEND_FACT: value}),
                             value)
        for value in ("grub2", "", True):
            with self.assertRaisesRegex(ValueError, "unknown snapshot"):
                catalog.snapshot_backend({catalog.SNAPSHOT_BACKEND_FACT: value})

    def test_unsupported_snapshot_schema_fails_closed(self):
        for change in ({"schemaVersion": 2}, {"kind": "other"}, {"targets": []}):
            with self.assertRaises(ValueError):
                catalog.snapshot_candidates(dict(SNAPSHOT, **change))


class ProvenOnlyBrandTests(unittest.TestCase):
    def brand(self, policy, snapshot=SNAPSHOT):
        return catalog.tunaos_catalog(catalog.snapshot_candidates(snapshot),
                                      catalog.resolve_entries(SOURCE, policy))

    def test_only_images_with_a_passing_run_are_shown(self):
        unproven = dict(PROVEN, id="yellowfin-gnome", status="green",
                        source={"family": "Yellowfin", "desktop": "gnome", "suffix": ""})
        del unproven["evidence"]
        shown = self.brand([*POLICY, unproven, PROVEN])
        self.assertEqual([image["id"] for image in shown], ["yellowfin-xfce"])
        self.assertNotIn("evidence", shown[0])
        self.assertFalse(shown[0]["composeFs"])
        with self.assertRaisesRegex(ValueError, "no TunaOS snapshot candidate"):
            self.brand([*POLICY, unproven])

    def test_evidence_must_be_a_run_on_a_green_entry(self):
        for change in ({"status": "experimental"}, {"evidence": {"run": 0}}, {"evidence": {"run": "123"}},
                       {"evidence": {"run": 1, "verdict": "passed"}}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.brand([dict(PROVEN, **change)])

    def test_proven_image_missing_from_the_snapshot_fails_closed(self):
        snapshot = dict(SNAPSHOT, targets=[target("yellowfin", "xfce", available=False), target("yellowfin", "gnome")])
        with self.assertRaisesRegex(ValueError, "not a generic amd64 target"):
            self.brand([PROVEN], snapshot)

    def test_snapshot_backend_must_agree_with_reviewed_backend(self):
        for backend, ok in (("ostree", True), ("composefs", False)):
            snapshot = dict(SNAPSHOT, targets=[target("yellowfin", "xfce",
                                                      facts={catalog.SNAPSHOT_BACKEND_FACT: backend})])
            if ok:
                self.assertEqual(len(self.brand([PROVEN], snapshot)), 1)
            else:
                with self.assertRaisesRegex(ValueError, "conflicts with reviewed backend"):
                    self.brand([PROVEN], snapshot)


class CatalogCommandTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.data = self.root / "app/data"
        self.data.mkdir(parents=True)
        self.brand = self.root / catalog.TUNAOS_BRAND_CATALOG
        self.brand.parent.mkdir(parents=True)
        raw = catalog.render(SOURCE)
        self.policy = [*POLICY, PROVEN]
        for name, content in {
            "catalog-sources.json": raw,
            "catalog-provenance.json": catalog.render(provenance(raw)),
            "catalog-policy.json": catalog.render(self.policy),
            "images.json": catalog.render(catalog.resolve(SOURCE, self.policy)),
            catalog.SNAPSHOT_FILE: catalog.render(SNAPSHOT),
        }.items():
            (self.data / name).write_bytes(content)
        self.brand.write_bytes(catalog.render([catalog.resolve(SOURCE, [PROVEN])[0]]))

    def snapshot(self):
        files = {path.name: path.read_bytes() for path in self.data.iterdir()}
        files["brand"] = self.brand.read_bytes()
        return files

    def command(self, *args):
        with redirect_stdout(io.StringIO()):
            return catalog.main(["--root", str(self.root), *args])

    def test_check_is_offline_read_only_and_deterministic(self):
        before = self.snapshot()
        with patch.object(catalog, "urlopen", side_effect=AssertionError("offline check fetched network")):
            self.assertEqual(self.command("--check"), 0)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(catalog.render(catalog.resolve(SOURCE, self.policy)), before["images.json"])

    def test_generated_drift_is_rejected_without_writing(self):
        (self.data / "images.json").write_bytes(b"[]\n")
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "generated images.json drift"):
            self.command("--check")
        self.assertEqual(self.snapshot(), before)

    def test_brand_catalog_drift_is_rejected_without_writing(self):
        self.brand.write_bytes(b"[]\n")
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "branding/tunaos/images.json drift"):
            self.command("--check")
        self.assertEqual(self.snapshot(), before)

    def test_tunaos_snapshot_pin_drift_is_rejected(self):
        changed = dict(SNAPSHOT, generatedAt="2026-11-21T00:00:00Z")
        (self.data / catalog.SNAPSHOT_FILE).write_bytes(catalog.render(changed))
        with self.assertRaisesRegex(ValueError, "TunaOS snapshot drifted"):
            self.command("--check")

    def test_snapshot_update_pins_exact_bytes_and_regenerates_brand(self):
        snapshot = dict(SNAPSHOT, generatedAt="2026-11-21T00:00:00Z", snapshotDigest="sha256:" + "b" * 64,
                        targets=[target("yellowfin", "xfce"), target("skipjack", "gnome")])
        raw = json.dumps(snapshot).encode()
        with patch.object(catalog, "urlopen", return_value=io.BytesIO(raw)) as fetch:
            self.assertEqual(self.command("--snapshot"), 0)
        self.assertEqual(fetch.call_args.args[0].full_url, catalog.SNAPSHOT_URL)
        self.assertEqual((self.data / catalog.SNAPSHOT_FILE).read_bytes(), raw)
        pin = json.loads((self.data / "catalog-provenance.json").read_bytes())["tunaosSnapshot"]
        self.assertEqual((pin["generatedAt"], pin["snapshotDigest"], pin["sha256"]),
                         (snapshot["generatedAt"], snapshot["snapshotDigest"], hashlib.sha256(raw).hexdigest()))
        self.assertEqual(self.command("--check"), 0)

    def test_snapshot_update_that_drops_a_proven_image_writes_nothing(self):
        snapshot = dict(SNAPSHOT, targets=[target("yellowfin", "gnome")])
        before = self.snapshot()
        with patch.object(catalog, "urlopen", return_value=io.BytesIO(catalog.render(snapshot))):
            with self.assertRaisesRegex(ValueError, "not a generic amd64 target"):
                self.command("--snapshot")
        self.assertEqual(self.snapshot(), before)

    def test_candidates_list_proof_and_unknown_backend(self):
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(catalog.main(["--root", str(self.root), "--candidates"]), 0)
        self.assertEqual(output.getvalue().splitlines(), [
            "yellowfin:xfce:linux/amd64\tghcr.io/tuna-os/yellowfin:xfce\tunknown\tproven:123",
            "yellowfin:gnome:linux/amd64\tghcr.io/tuna-os/yellowfin:gnome\tunknown\tunproven",
        ])

    def test_snapshot_hash_drift_is_rejected(self):
        with (self.data / "catalog-sources.json").open("ab") as output:
            output.write(b"\n")
        with self.assertRaisesRegex(ValueError, "snapshot hash drift"):
            self.command("--check")

    def test_policy_edits_regenerate_only_the_derived_artifact(self):
        policy = copy.deepcopy(self.policy)
        policy[0]["name"] = "Reviewed local name"
        (self.data / "catalog-policy.json").write_bytes(catalog.render(policy))
        before = self.snapshot()
        self.assertEqual(self.command(), 0)
        after = self.snapshot()
        self.assertEqual({key for key in before if before[key] != after[key]}, {"images.json"})
        policy[1]["name"] = "Proven local name"
        (self.data / "catalog-policy.json").write_bytes(catalog.render(policy))
        self.assertEqual(self.command(), 0)
        self.assertEqual(json.loads(self.brand.read_bytes())[0]["name"], "Proven local name")
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
        self.assertEqual(fetch.call_args.args[0].full_url,
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
