#!/usr/bin/env python3
"""Build a branded Windows GUI executable without modifying checkout resources.

Requires Go and a built app/frontend/dist. icon.ico is preferred; logo.svg is
rendered with rsvg-convert when available. Missing artwork falls back explicitly
to the platform icon. RELEASE_TAG supplies version metadata for release builds.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

WINRES = "github.com/tc-hib/go-winres@v0.3.3"
ROOT = Path(__file__).resolve().parents[1]


def fixed_version(version):
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?(?:[-+][0-9A-Za-z.-]+)?", version)
    if not match:
        # Auto/manual release tags are opaque; preserve them in the string
        # fields rather than inventing a misleading numeric version.
        return "0.0.0.0"
    parts = [int(part or 0) for part in match.groups()]
    if any(part > 65535 for part in parts):
        raise ValueError("Windows numeric version components must be <= 65535")
    return ".".join(map(str, parts))


def resources(root, brand, version, work):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", brand):
        raise ValueError("brand must be a lowercase directory identifier")
    directory = root / "app/branding" / brand
    if not (directory / "brand.json").is_file():
        raise ValueError(f"unknown brand: {brand}")
    config = json.loads((directory / "brand.json").read_text())
    for field in ("name", "productName", "exeName"):
        if not isinstance(config.get(field), str) or not config[field].strip():
            raise ValueError(f"{brand}: {field} is required")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", config["exeName"]):
        raise ValueError(f"{brand}: unsafe exeName")
    if not re.fullmatch(r"[A-Za-z0-9.+_-]+", version):
        raise ValueError("version must be a release tag without whitespace")
    numeric = fixed_version(version)
    manifest = ET.parse(root / "app/build/windows/wootc.manifest")
    ns = "{urn:schemas-microsoft-com:asm.v1}"
    manifest.find(ns + "assemblyIdentity").set("name", config["exeName"])
    manifest.find(ns + "assemblyIdentity").set("version", numeric)
    manifest.find(ns + "description").text = config.get("fileDescription") or config["productName"]
    manifest_path = work / "app.manifest"
    manifest.write(manifest_path, encoding="utf-8", xml_declaration=True)
    icon = directory / "icon.ico"
    if not icon.is_file():
        logo = directory / "logo.svg"
        if logo.is_file() and shutil.which("rsvg-convert"):
            icon = work / "icon.png"
            subprocess.run(["rsvg-convert", "-w", "256", "-h", "256", str(logo), "-o", str(icon)], check=True)
        else:
            print(f"{brand}: using platform icon (supply icon.ico or logo.svg + rsvg-convert)", file=sys.stderr)
            icon = root / "app/build/windows/icon.ico"
    info = {
        "ProductName": config["productName"],
        "FileDescription": config.get("fileDescription") or config["productName"],
        "CompanyName": config.get("publisher") or config["name"],
        "LegalCopyright": config.get("copyright") or "",
        "OriginalFilename": config["exeName"] + ".exe",
        "InternalName": config["exeName"],
        "ProductVersion": version,
        "FileVersion": version,
    }
    return {
        "RT_MANIFEST": {"#1": {"0409": os.path.relpath(manifest_path, work)}},
        "RT_GROUP_ICON": {"APP": {"0000": os.path.relpath(icon, work)}},
        "RT_VERSION": {"#1": {"0000": {
            "fixed": {"file_version": numeric, "product_version": numeric},
            "info": {"0409": info},
        }}},
    }


def build(root, brand, output, version, tags, ldflags):
    output = Path(output).resolve()
    # Isolate resources as well as source: simultaneous builds cannot inherit
    # another brand's .syso, and a failed build never dirties the source tree.
    with tempfile.TemporaryDirectory(prefix="wootc-windows-") as tmp:
        work = Path(tmp)
        config = resources(root, brand, version, work)
        source = work / "app"
        shutil.copytree(root / "app", source,
                        ignore=shutil.ignore_patterns("node_modules", "*.syso", ".git", "*.exe"))
        resource_json = work / "winres.json"
        resource_json.write_text(json.dumps(config))
        subprocess.run(["go", "run", WINRES, "make", "--arch", "amd64", "--in", str(resource_json),
                        "--out", str(source / "rsrc")], check=True, cwd=root)
        output.parent.mkdir(parents=True, exist_ok=True)
        # The protected flags come last so callers cannot accidentally remove
        # the GUI subsystem or compile a different runtime brand identity.
        flags = f"{ldflags} -H windowsgui -w -s -X main.brandID={brand}"
        if version != "0.0.0-dev":
            flags += f" -X main.releaseTag={version}"
        subprocess.run(["go", "build", "-tags", tags, "-ldflags", flags, "-o", str(output), "."],
                       cwd=source, env={**os.environ, "GOOS": "windows", "GOARCH": "amd64", "CGO_ENABLED": "0"}, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--brand", default="wootc")
    parser.add_argument("--output", required=True)
    parser.add_argument("--version", default=os.environ.get("RELEASE_TAG") or "0.0.0-dev")
    parser.add_argument("--tags", default="desktop,production,native_webview2loader")
    parser.add_argument("--ldflags", default="")
    args = parser.parse_args()
    try:
        build(ROOT, args.brand, args.output, args.version, args.tags, args.ldflags)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Windows build failed: {error}\n")


if __name__ == "__main__":
    main()
