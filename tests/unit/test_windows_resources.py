#!/usr/bin/env python3
"""Inspect linked PE resources, not build-script text or generated inputs."""
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("build_windows", ROOT / "packaging/build-windows.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def pe_resources(path):
    data = path.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3c)[0]
    assert data[pe:pe + 4] == b"PE\0\0"
    sections, optional_size = struct.unpack_from("<H", data, pe + 6)[0], struct.unpack_from("<H", data, pe + 20)[0]
    optional = pe + 24
    subsystem = struct.unpack_from("<H", data, optional + 68)[0]
    table = optional + optional_size
    ranges = []
    for i in range(sections):
        entry = table + i * 40
        size, rva, raw_size, offset = struct.unpack_from("<IIII", data, entry + 8)
        ranges.append((rva, rva + max(size, raw_size), offset))
    def file_offset(rva):
        for start, end, offset in ranges:
            if start <= rva < end:
                return offset + rva - start
        raise AssertionError(f"unmapped RVA {rva}")
    base = file_offset(struct.unpack_from("<I", data, optional + 112 + 2 * 8)[0])
    result = {}
    def walk(relative, keys):
        directory = base + relative
        named, ids = struct.unpack_from("<HH", data, directory + 12)
        for i in range(named + ids):
            name, target = struct.unpack_from("<II", data, directory + 16 + i * 8)
            if name & 0x80000000:
                string = base + (name & 0x7fffffff)
                length = struct.unpack_from("<H", data, string)[0]
                name = data[string + 2:string + 2 + length * 2].decode("utf-16le")
            if target & 0x80000000:
                walk(target & 0x7fffffff, keys + (name,))
            else:
                rva, size = struct.unpack_from("<II", data, base + target)
                offset = file_offset(rva)
                result[keys + (name,)] = data[offset:offset + size]
    walk(0, ())
    return subsystem, result


class WindowsResources(unittest.TestCase):
    def test_version_rules(self):
        self.assertEqual(builder.fixed_version("v1.2.3-rc.2"), "1.2.3.0")
        self.assertEqual(builder.fixed_version("auto-v20260926-abcdef0"), "0.0.0.0")
        with self.assertRaises(ValueError):
            builder.fixed_version("1.2.65536")

    def test_unknown_brand_fails_before_go(self):
        with tempfile.TemporaryDirectory() as tmp:
            for brand in ("no-such-brand", "../wootc", "wootc -X main.bad=1"):
                with self.subTest(brand=brand), self.assertRaises(ValueError):
                    builder.resources(ROOT, brand, "v1.2.3", Path(tmp))

    @unittest.skipUnless(shutil.which("go"), "Go required for PE link verification")
    def test_linked_brand_resources_and_isolation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / "app"
            app.mkdir()
            (app / "rsrc_windows_amd64.syso").write_bytes(b"existing platform resource")
            (app / "go.mod").write_text("module fixture\n\ngo 1.22\n")
            (app / "main.go").write_text('package main\nvar brandID, releaseTag string\nfunc main() {}\n')
            shutil.copytree(ROOT / "app/build/windows", app / "build/windows")
            original = ROOT / "app/build/windows/icon.ico"
            icons = {}
            for brand, name in (("first", "First & Co"), ("second", "Second")):
                directory = app / "branding" / brand
                directory.mkdir(parents=True)
                config = dict(name=name, productName=name + " Installer", exeName=brand,
                              publisher=name + " Project", copyright="© 2026 " + name,
                              fileDescription=name + " migration")
                (directory / "brand.json").write_text(json.dumps(config))
                # Two distinct valid icons: choose different source image entries.
                ico = original.read_bytes()
                count = struct.unpack_from("<H", ico, 4)[0]
                index = 0 if brand == "first" else count - 1
                entry = bytearray(ico[6 + index * 16:22 + index * 16])
                size, offset = struct.unpack_from("<II", entry, 8)
                payload = ico[offset:offset + size]
                struct.pack_into("<I", entry, 12, 22)
                (directory / "icon.ico").write_bytes(struct.pack("<HHH", 0, 1, 1) + entry + payload)
                icons[brand] = payload
                output = root / (brand + ".exe")
                builder.build(root, brand, output, "v2.3.4-rc.1", "", "")
                subsystem, resources = pe_resources(output)
                self.assertEqual(subsystem, 2, "must be Windows GUI, not console")
                manifest = resources[(24, 1, 1033)].decode("utf-8")
                self.assertIn('level="requireAdministrator"', manifest)
                self.assertIn("PerMonitorV2", manifest)
                self.assertIn("8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a", manifest)
                fixed = next(value for key, value in resources.items() if key[:2] == (16, 1))
                version = fixed.decode("utf-16le", errors="surrogatepass")
                for expected in (config["productName"], config["publisher"], config["copyright"],
                                 config["fileDescription"], brand + ".exe", "v2.3.4-rc.1"):
                    self.assertIn(expected + "\0", version)
                signature = fixed.index(struct.pack("<I", 0xfeef04bd))
                self.assertEqual(struct.unpack_from("<II", fixed, signature + 8), (2 << 16 | 3, 4 << 16))
                self.assertIn(payload, [value for key, value in resources.items() if key[0] == 3])
            self.assertNotEqual(icons["first"], icons["second"])
            self.assertEqual((app / "rsrc_windows_amd64.syso").read_bytes(), b"existing platform resource")


if __name__ == "__main__":
    unittest.main()
