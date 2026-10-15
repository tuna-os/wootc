#!/usr/bin/env python3
"""Render a draft winget package, with quoted YAML values from brand metadata."""
import importlib.util
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("wootc_brand", Path(__file__).resolve().parents[1] / "brand.py")
brand_rules = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(brand_rules)


def text_field(config, key, fallback=""):
    value = config.get(key) or fallback
    if not isinstance(value, str):
        raise ValueError(f"{key} must be text")
    return value


def render(root, brand, version="", url="", sha=""):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", brand):
        raise ValueError("invalid brand identifier")
    directory = root / "app/branding" / brand
    if not directory.is_dir():
        raise ValueError(f"no such brand: {brand}")
    if not (directory / "blessing.json").is_file():
        raise ValueError(f"{brand} has no blessing.json (#227) — nothing to offer until someone is being asked")
    blessing = json.loads((directory / "blessing.json").read_text())
    config = json.loads((directory / "brand.json").read_text())
    winget = blessing.get("winget", {})
    identifier = text_field(winget, "identifier")
    if not re.fullmatch(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+", identifier):
        raise ValueError(f"{brand}: invalid or missing winget.identifier")
    required = {field: text_field(config, field) for field in ("name", "productName", "tagline", "exeName")}
    if not all(value.strip() for value in required.values()):
        raise ValueError(f"{brand}: brand.json is missing name/productName/tagline/exeName")
    name, product = required["name"], required["productName"]
    fallback = text_field(blessing.get("mark", {}), "assetSource")
    if not fallback.startswith(("https://", "http://")):
        fallback = "https://github.com/tuna-os/wootc"
    website = text_field(config, "websiteURL", fallback)
    support = text_field(config, "supportURL", "https://github.com/tuna-os/wootc/issues")
    agreed = winget.get("identifierAgreed") is True
    # Same authorship rule as the exe's CompanyName: the mark's owner is named
    # as publisher only once they said yes; until then, the distributor.
    if brand_rules.owner_may_be_named(root, brand):
        publisher = text_field(config, "publisher", identifier.split(".")[0])
        publisher_url = website
    else:
        publisher = brand_rules.effective_identity(root, brand, config)[0]
        publisher_url = "https://github.com/tuna-os/wootc"
    permission = (f"The {name} name and mark are used with the {name} project's permission." if agreed else
                  "PERMISSION NOT YET GRANTED — this is a draft offered for review, not a submission.")
    # Say what the installer really does to the disk. On most PCs that is one
    # folder on C:; when BitLocker encrypts C:, it shrinks C: and adds one
    # unencrypted data partition (app/disk_windows.go). "No partitions are
    # touched" is false on exactly the PCs Windows 11 ships encrypted.
    description = (
        f"{product} installs {name} from inside Windows. On most PCs everything\n"
        "lives in one folder on your Windows drive. If BitLocker encrypts that\n"
        "drive, the installer shrinks it and adds one unencrypted data partition;\n"
        "uninstall can remove that partition and give the space back to Windows.\n"
        "Windows stays the default boot and your files are bridged into Linux.\n\n"
        "Built by the wootc project (https://github.com/tuna-os/wootc).\n" + permission)
    values = {
        "IDENTIFIER": identifier,
        "VERSION": version or "{{VERSION}}",
        "URL": url or "{{URL}}",
        "SHA256": sha or "{{SHA256}}",
        "PUBLISHER": publisher,
        "PUBLISHER_URL": publisher_url,
        "SUPPORT_URL": support,
        "PACKAGE_URL": text_field(config, "websiteURL", "https://github.com/tuna-os/wootc"),
        "PACKAGE_NAME": product,
        "TAGLINE": required["tagline"],
        "COMMAND": required["exeName"],
        "MONIKER": identifier.lower().replace(".", "-"),
        "DESCRIPTION": description,
        "RELEASE_NOTES_URL": "https://github.com/tuna-os/wootc/releases/tag/" + ("v" + version if version else "{{TAG}}"),
    }
    # JSON strings are valid YAML quoted scalars. A single regex pass avoids
    # interpreting another field's replacement tokens as template instructions.
    def substitute(match):
        key = match.group(1)
        return identifier if key == "IDENTIFIER" else json.dumps(values[key])
    def comment(value):
        return " ".join(str(value).splitlines())
    owner = text_field(winget, "namespaceOwner")
    header = (
        f"# winget manifests for {comment(product)} ({identifier})\n#\n"
        f"# Namespace owner : {comment(owner)}\n"
        f"# Blessing status : {comment(blessing.get('status', ''))} (identifier agreed: {str(agreed).lower()})\n"
        "# Rendered by     : packaging/winget/render-brand.sh — NOT submitted anywhere.\n#\n"
        f"# {identifier} is {comment(owner)}'s to publish. These are offered so that decision can\n"
        "# be made against the real thing; take them over, ask us to publish on your\n"
        "# behalf, or say no and nothing is submitted.\n")
    result = [header]
    for part in ("version", "installer", "locale.en-US"):
        template = (root / "packaging/winget/brand" / (part + ".yaml.in")).read_text()
        result.append(f"\n--- {identifier}.{part}.yaml ---\n")
        result.append(re.sub(r"\{\{([A-Z_0-9]+)\}\}", substitute, template))
    return "".join(result)


def main():
    if not 2 <= len(sys.argv) <= 5:
        raise ValueError("usage: render-brand.sh <brand> [version] [url] [sha256]")
    print(render(ROOT, *sys.argv[1:]), end="")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        sys.exit(f"render-brand.sh: {error}")
