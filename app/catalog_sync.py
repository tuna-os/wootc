#!/usr/bin/env python3
"""Synchronize the reviewed image catalog without importing publication as support.

  python3 app/catalog_sync.py --check
  python3 app/catalog_sync.py                 # regenerate images.json after policy edits
  python3 app/catalog_sync.py --revision SHA  # review and pin an exact upstream commit

The offline check validates the pinned source hash/schema, rejects duplicate local
identity/backend fields for shared images, checks wootc bootloader policy against
the source backend, and rejects drift in the generated images.json consumed by
packaging/E2E tooling. The application resolves source + policy directly; its Go
parity test checks this generated artifact. No registry probes or catalog-feed
publication statuses are promoted into wootc support evidence.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/tuna-os/bootc-migrate"
SOURCE_PATH = "catalog/sources.json"
IMAGE_FIELDS = (
    "id", "name", "emoji", "base", "desktop", "desktopName", "imageRef",
    "description", "bootloader", "composeFs", "family", "status", "mokEnroll",
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def valid_ref(ref):
    return (isinstance(ref, str) and len(ref) <= 200
            and re.fullmatch(r"ghcr\.io/[A-Za-z0-9._/:-]+", ref) is not None)


def fields(value, allowed, required, label):
    require(isinstance(value, dict), f"{label} must be an object")
    require(not (value.keys() - set(allowed)), f"unknown {label} fields")
    require(set(required) <= value.keys(), f"missing {label} fields")


def source_index(source):
    fields(source, ("version", "images", "families"), ("version", "images"), "source")
    require(type(source["version"]) is int and source["version"] == 1,
            "unsupported catalog source version")
    require(isinstance(source["images"], list) and 0 < len(source["images"]) <= 512,
            "invalid reviewed catalog image count")
    images, families, refs = {}, {}, {}

    def add_ref(ref, backend):
        require(valid_ref(ref), f"invalid reviewed image reference {ref!r}")
        require(ref not in refs or refs[ref] == backend,
                f"conflicting reviewed backends for {ref}")
        refs[ref] = backend

    for image in source["images"]:
        fields(image, ("name", "image", "backend", "published"),
               ("name", "image", "backend", "published"), "image")
        name, ref, backend = image["name"], image["image"], image["backend"]
        require(isinstance(name, str) and name and name not in images,
                f"invalid or duplicate reviewed image {name!r}")
        require(backend in ("ostree", "composefs") and type(image["published"]) is bool,
                f"invalid reviewed image {name}")
        require(isinstance(ref, str), "image reference must be a string")
        if ref:
            require(ref not in refs, f"duplicate reviewed image reference {ref}")
            add_ref(ref, backend)
        else:
            require(not image["published"], "published reviewed image has no reference")
        images[name] = image
    require(isinstance(source.get("families", []), list), "families must be a list")
    for family in source.get("families", []):
        keys = ("name", "repository", "backend", "desktops", "suffixes")
        fields(family, keys, keys, "family")
        name, backend = family["name"], family["backend"]
        require(isinstance(name, str) and name and name not in families,
                f"invalid or duplicate reviewed family {name!r}")
        require(backend in ("ostree", "composefs"), f"invalid reviewed family {name}")
        require(isinstance(family["repository"], str), "repository must be a string")
        for key in ("desktops", "suffixes"):
            require(isinstance(family[key], list) and family[key]
                    and all(isinstance(value, str) for value in family[key]),
                    f"invalid family {key}")
        for desktop in family["desktops"]:
            require(desktop, "empty reviewed desktop")
            for suffix in family["suffixes"]:
                add_ref(family["repository"] + ":" + desktop + suffix, backend)
        families[name] = family
    require(len(refs) <= 512, "reviewed catalog is too large")
    return images, families, refs


def resolve(source, policy):
    images, families, upstream_refs = source_index(source)
    require(isinstance(policy, list) and policy, "wootc catalog policy is empty")
    result, ids, refs = [], set(), set()
    for entry in policy:
        fields(entry, (*IMAGE_FIELDS, "source"), ("id", "name", "bootloader"), "policy")
        for key, value in entry.items():
            if key == "source":
                continue
            require(type(value) is bool if key == "composeFs" else isinstance(value, str),
                    f"invalid policy field {key}")
        identifier = entry["id"]
        require(identifier and entry["name"] and identifier not in ids,
                f"invalid or duplicate wootc catalog ID {identifier!r}")
        image = {key: value for key, value in entry.items() if key != "source"}
        if entry.get("source") is not None:
            require("imageRef" not in entry and "composeFs" not in entry,
                    f"{identifier} duplicates upstream identity or backend")
            selector = entry["source"]
            fields(selector, ("image", "family", "desktop", "suffix"), (), "selector")
            require(all(isinstance(value, str) for value in selector.values()),
                    "selector values must be strings")
            if selector.get("image"):
                require(not any(selector.get(key) for key in ("family", "desktop", "suffix")),
                        "mixed primary and family source selector")
                require(selector["image"] in images, "unknown reviewed image")
                selected = images[selector["image"]]
                ref, backend = selected["image"], selected["backend"]
                require(ref, "reviewed image has no reference")
            else:
                require(selector.get("family") in families, "unknown reviewed family")
                family = families[selector["family"]]
                desktop, suffix = selector.get("desktop", ""), selector.get("suffix", "")
                require(desktop in family["desktops"] and suffix in family["suffixes"],
                        "unreviewed family tag")
                ref, backend = family["repository"] + ":" + desktop + suffix, family["backend"]
            image["imageRef"], image["composeFs"] = ref, backend == "composefs"
        else:
            require(valid_ref(image.get("imageRef")) and "composeFs" in image,
                    f"{identifier} requires an explicit local identity and backend")
            ref = image["imageRef"]
            require(ref not in upstream_refs, f"{identifier} must select its shared upstream source")
            backend = "composefs" if image["composeFs"] else "ostree"
        # These are wootc's explicitly reviewed supported stacks. Upstream does
        # not publish bootloader metadata; this is not upstream boot evidence.
        require((backend, image["bootloader"]) in (("ostree", "grub2"), ("composefs", "systemd-boot")),
                f"{identifier}: reviewed wootc bootloader conflicts with source backend {backend}")
        require(ref not in refs, f"duplicate wootc image reference {ref}")
        ids.add(identifier)
        refs.add(ref)
        result.append({key: image[key] for key in IMAGE_FIELDS if key in image})
    return result


def render(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def validate_provenance(provenance, raw):
    keys = ("repository", "revision", "path", "sha256")
    fields(provenance, keys, keys, "provenance")
    require(provenance["repository"] == REPOSITORY and provenance["path"] == SOURCE_PATH,
            "unexpected catalog source provenance")
    require(isinstance(provenance["revision"], str)
            and re.fullmatch(r"[0-9a-f]{40}", provenance["revision"]),
            "catalog revision must be a full immutable commit")
    require(provenance["sha256"] == hashlib.sha256(raw).hexdigest(),
            "reviewed source snapshot hash drift")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="offline drift check; never write files")
    mode.add_argument("--revision", help="fetch exact reviewed upstream commit and regenerate")
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    data = args.root / "app/data"
    if args.revision is not None:
        require(re.fullmatch(r"[0-9a-f]{40}", args.revision), "--revision requires a full immutable commit")
        url = f"https://raw.githubusercontent.com/tuna-os/bootc-migrate/{args.revision}/{SOURCE_PATH}"
        with urlopen(url, timeout=30) as response:
            raw = response.read()
        provenance = {"repository": REPOSITORY, "revision": args.revision,
                      "path": SOURCE_PATH, "sha256": hashlib.sha256(raw).hexdigest()}
    else:
        raw = (data / "catalog-sources.json").read_bytes()
        provenance = json.loads((data / "catalog-provenance.json").read_bytes())
    validate_provenance(provenance, raw)
    policy = json.loads((data / "catalog-policy.json").read_bytes())
    generated = render(resolve(json.loads(raw), policy))
    if args.check:
        require((data / "images.json").read_bytes() == generated,
                "generated images.json drift; run python3 app/catalog_sync.py and review the diff")
        print(f"Reviewed catalog synchronized at {provenance['revision']}")
    else:
        # Resolve everything before changing any file: unsupported schemas and
        # changed backend/boot policy fail without modifying the reviewed pin.
        if args.revision is not None:
            (data / "catalog-sources.json").write_bytes(raw)
            (data / "catalog-provenance.json").write_bytes(render(provenance))
        (data / "images.json").write_bytes(generated)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"catalog: {error}", file=sys.stderr)
        sys.exit(1)
