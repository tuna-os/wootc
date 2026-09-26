#!/usr/bin/env python3
"""Exercise winget rendering with distributor metadata and hostile scalar text."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("render_brand", ROOT / "packaging/winget/render-brand.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class WingetBrand(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.directory = self.root / "app/branding/example"
        self.directory.mkdir(parents=True)
        shutil.copytree(ROOT / "packaging/winget/brand", self.root / "packaging/winget/brand")
        self.brand = dict(name="Example", productName="Example Installer", tagline="Try Example", exeName="Example-Installer")
        self.blessing = dict(status="pending", mark=dict(assetSource="https://old.example/home"),
                             winget=dict(identifier="Example.Installer", namespaceOwner="Example Project", identifierAgreed=False))

    def render(self):
        (self.directory / "brand.json").write_text(json.dumps(self.brand))
        (self.directory / "blessing.json").write_text(json.dumps(self.blessing))
        return renderer.render(self.root, "example", "1.2.3", 'https://example.org/a?x=1&y="two"', "a" * 64)

    def field(self, rendered, name):
        # The renderer intentionally emits JSON-compatible YAML string scalars;
        # decode the exact text consumers read, including escapes and Unicode.
        lines = [line.strip() for line in rendered.splitlines() if line.strip().startswith(name + ": ")]
        self.assertTrue(lines, name)
        return json.loads(lines[0].split(": ", 1)[1])

    def test_brand_publisher_and_links_replace_upstream_identity(self):
        self.brand.update(publisher='Example: "Friends" & Co', websiteURL="https://example.org/?a=1&b=2", supportURL="https://help.example.org/")
        output = self.render()
        for field, expected in (("Publisher", self.brand["publisher"]), ("PublisherUrl", self.brand["websiteURL"]),
                                ("PackageUrl", self.brand["websiteURL"]), ("PublisherSupportUrl", self.brand["supportURL"])):
            self.assertEqual(self.field(output, field), expected)
        self.assertIn("License: GPL-2.0 OR MIT", output)
        self.assertIn("https://github.com/tuna-os/wootc/blob/main/LICENSE-GPL-2.0", output)
        self.assertIn("Built by the wootc project", self.field(output, "Description"))

    def test_existing_brands_keep_backward_compatible_fallbacks(self):
        output = self.render()
        self.assertEqual(self.field(output, "Publisher"), "Example")
        self.assertEqual(self.field(output, "PublisherUrl"), "https://old.example/home")
        self.assertEqual(self.field(output, "PackageUrl"), "https://github.com/tuna-os/wootc")
        self.assertEqual(self.field(output, "PublisherSupportUrl"), "https://github.com/tuna-os/wootc/issues")
        self.blessing["mark"]["assetSource"] = "emoji"
        self.assertEqual(self.field(self.render(), "PublisherUrl"), "https://github.com/tuna-os/wootc")

    def test_quotes_newlines_colons_ampersands_and_tokens_cannot_inject_yaml(self):
        hostile = 'Example: "A&B" | \\ path\nInjected: true\n---\n{{VERSION}} café'
        for key in ("name", "productName", "publisher", "tagline", "exeName"):
            self.brand[key] = hostile
        self.blessing["winget"]["namespaceOwner"] = hostile
        output = self.render()
        self.assertEqual(self.field(output, "PackageName"), hostile)
        self.assertEqual(self.field(output, "Publisher"), hostile)
        self.assertEqual(self.field(output, "ShortDescription"), hostile)
        self.assertEqual(self.field(output, "InstallerUrl"), 'https://example.org/a?x=1&y="two"')
        self.assertIn(hostile, self.field(output, "Description"))
        self.assertNotIn("\nInjected:", output)
        self.assertNotIn("\n---\n", output)
        self.assertEqual(self.field(output, "PackageVersion"), "1.2.3")

    def test_only_boolean_agreement_grants_permission(self):
        for agreed in (False, "true", None):
            self.blessing["winget"]["identifierAgreed"] = agreed
            self.assertIn("PERMISSION NOT YET GRANTED", self.field(self.render(), "Description"))
        self.blessing["winget"]["identifierAgreed"] = True
        self.assertIn("used with the Example project's permission", self.field(self.render(), "Description"))

    def test_traversal_and_identifier_injection_fail(self):
        for brand in ("../example", "/tmp/example", "example/../example", "example\nInjected"):
            with self.subTest(brand=brand), self.assertRaises(ValueError):
                renderer.render(self.root, brand)
        for identifier in ("MissingDot", "Example.Installer\nInjected: true", "../Example.Installer"):
            self.blessing["winget"]["identifier"] = identifier
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                self.render()


if __name__ == "__main__":
    unittest.main()
