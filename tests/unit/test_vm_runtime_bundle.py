#!/usr/bin/env python3
"""Verify runtime package contents and that fixture private keys stay outside."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("runtime_builder", ROOT / "packaging/build-vm-runtime.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class RuntimeBundle(unittest.TestCase):
    def fixture(self, root):
        source = root / "source"
        for name in builder.REQUIRED:
            file = source / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(b"fixture " + name.encode())
        for name in ("dependency.dll", "qemu-system-aarch64.exe", "share/edk2-aarch64-code.fd"):
            (source / name).write_bytes(b"fixture")
        helper = root / "helper"
        helper.mkdir()
        for name in ("builder-vmlinuz", "builder-initramfs.img"):
            (helper / name).write_bytes(b"test helper")
        (helper / "builder-protocol.json").write_text(json.dumps({"protocol": "wootc-helper", "protocolVersion": 1}))
        return source, helper

    def test_archive_contains_only_selected_runtime_and_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, helper = self.fixture(root)
            private = root / "seed"
            private.write_bytes(b"NEVER PUBLISH THIS PRIVATE SEED")
            runtime = root / "qemu"
            builder.create_runtime(source, runtime, helper, {"version": "fixture"})
            manifest = (runtime / "SHA256SUMS").read_text()
            self.assertIn("dependency.dll", manifest)
            self.assertIn("share/edk2-x86_64-code.fd", manifest)
            self.assertIn("builder-initramfs.img", manifest)
            self.assertNotIn("aarch64", manifest)
            self.assertNotIn("seed", manifest)
            (runtime / "SHA256SUMS.sig").write_bytes(b"fixture signature")
            output = root / "runtime.zip"
            builder.archive_runtime(runtime, output)
            with zipfile.ZipFile(output) as archive:
                self.assertIn("qemu/SHA256SUMS.sig", archive.namelist())
                self.assertIn("qemu/COPYING", archive.namelist())
                self.assertFalse(any(name.startswith("/") or ".." in Path(name).parts for name in archive.namelist()))
                self.assertFalse(any(private.read_bytes() in archive.read(name) for name in archive.namelist()))
            output2 = root / "runtime2.zip"
            builder.archive_runtime(runtime, output2)
            self.assertEqual(output.read_bytes(), output2.read_bytes())

    def test_missing_firmware_and_symlinks_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, _ = self.fixture(root)
            (source / "dependency.dll").unlink()
            (source / "dependency.dll").symlink_to(root / "outside")
            with self.assertRaises(ValueError):
                builder.selected_files(source)
            (source / "dependency.dll").unlink()
            (source / "share/edk2-i386-vars.fd").unlink()
            with self.assertRaises(ValueError):
                builder.selected_files(source)

    def test_bad_installer_hash_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            installer = root / "installer.exe"
            installer.write_bytes(b"not the pinned QEMU installer")
            with self.assertRaisesRegex(ValueError, "SHA-512"):
                builder.build(installer, root, root / "seed", root / "out.zip", "must-not-execute")


if __name__ == "__main__":
    unittest.main()
