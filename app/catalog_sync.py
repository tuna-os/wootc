#!/usr/bin/env python3
"""Synchronize the reviewed image catalog without importing publication as support.

  python3 app/catalog_sync.py --check
  python3 app/catalog_sync.py                 # regenerate images.json after policy edits
  python3 app/catalog_sync.py --revision SHA  # review and pin an exact upstream commit
  python3 app/catalog_sync.py --snapshot      # review and pin the current iso.tunaos.org snapshot
  python3 app/catalog_sync.py --candidates    # list TunaOS candidates and their wootc proof

The offline check validates the pinned source hash/schema, rejects duplicate local
identity/backend fields for shared images, checks wootc bootloader policy against
the source backend, and rejects drift in the generated images.json consumed by
packaging/E2E tooling. The application resolves source + policy directly; its Go
parity test checks this generated artifact. No registry probes or catalog-feed
publication statuses are promoted into wootc support evidence.

The TunaOS brand catalog (app/branding/tunaos/images.json) is generated too.
Its candidates are the generic amd64 targets of the pinned iso.tunaos.org
catalog snapshot, the matrix the ISO site offers. It shows a candidate only when
catalog-policy.json records a passing wootc install run for that image
("evidence"); the snapshot never grants support.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/tuna-os/bootc-migrate"
SOURCE_PATH = "catalog/sources.json"
SNAPSHOT_URL = "https://iso.tunaos.org/catalog-snapshot.json"
SNAPSHOT_FILE = "tunaos-catalog-snapshot.json"
TUNAOS_BRAND_CATALOG = "app/branding/tunaos/images.json"
TUNAOS_REPOSITORY_PREFIX = "ghcr.io/tuna-os/"
# Flavor tokens that need hardware a generic Windows PC does not have: an NVIDIA
# GPU, hardware-enablement kernels, the CachyOS kernel, Apple silicon or T2
# Macs, the ThinkPad X13s, or a ZFS root.
HARDWARE_FLAVOR_TOKENS = frozenset(("nvidia", "hwe", "cachyos", "asahi", "x13s", "t2", "zfs"))
# The snapshot fact that names the image's deployment backend. The catalog
# producer must observe it with the deployer's own probe
# (payload/deployer/deploy.sh, "Resolve deployment backend"); see snapshot_backend.
SNAPSHOT_BACKEND_FACT = "bootBackend"
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


def valid_evidence(evidence, identifier):
    fields(evidence, ("run",), ("run",), f"{identifier} evidence")
    require(type(evidence["run"]) is int and evidence["run"] > 0,
            f"{identifier} evidence must name a GitHub Actions run ID")


def resolve_entries(source, policy):
    """Resolve policy entries, in policy order, to (image, backend, evidence)."""
    images, families, upstream_refs = source_index(source)
    require(isinstance(policy, list) and policy, "wootc catalog policy is empty")
    result, ids, refs = [], set(), set()
    for entry in policy:
        fields(entry, (*IMAGE_FIELDS, "source", "evidence"), ("id", "name", "bootloader"), "policy")
        for key, value in entry.items():
            if key in ("source", "evidence"):
                continue
            require(type(value) is bool if key == "composeFs" else isinstance(value, str),
                    f"invalid policy field {key}")
        identifier = entry["id"]
        require(identifier and entry["name"] and identifier not in ids,
                f"invalid or duplicate wootc catalog ID {identifier!r}")
        image = {key: value for key, value in entry.items() if key not in ("source", "evidence")}
        evidence = entry.get("evidence")
        if evidence is not None:
            valid_evidence(evidence, identifier)
            # A passing wootc install run is what green means; evidence on an
            # experimental entry would show an image its channel still hides.
            require(entry.get("status") == "green", f"{identifier} has install evidence but is not green")
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
        result.append(({key: image[key] for key in IMAGE_FIELDS if key in image}, backend, evidence))
    return result


def resolve(source, policy):
    return [image for image, _, _ in resolve_entries(source, policy)]


def hardware_specific(flavor):
    return any(token in HARDWARE_FLAVOR_TOKENS for token in flavor.split("-"))


def snapshot_backend(facts):
    """Return the backend the snapshot observed, or None when it cannot say.

    Only the explicit observed fact counts. hasSdBoot and repoFamily are not
    backend evidence: the producer writes hasSdBoot=false for every target it
    did not probe (kernelVer, from the same probe, is empty on every target of
    the 2026-11 snapshots), and marlin is composefs in the reviewed source with
    hasSdBoot=false. repoFamily follows the build route, not the boot payload.
    None makes the candidate unprovable here; it never defaults to ostree.
    """
    require(isinstance(facts, dict), "snapshot target facts must be an object")
    value = facts.get(SNAPSHOT_BACKEND_FACT)
    if value is None:
        return None
    require(value in ("ostree", "composefs"), f"unknown snapshot {SNAPSHOT_BACKEND_FACT} {value!r}")
    return value


def snapshot_candidates(snapshot):
    """Map an iso.tunaos.org catalog snapshot to installable TunaOS candidates."""
    require(isinstance(snapshot, dict) and snapshot.get("kind") == "catalog-snapshot"
            and type(snapshot.get("schemaVersion")) is int and snapshot["schemaVersion"] == 1,
            "unsupported TunaOS catalog snapshot")
    targets = snapshot.get("targets")
    require(isinstance(targets, list) and 0 < len(targets) <= 2048, "invalid TunaOS snapshot target count")
    candidates, refs = [], set()
    for entry in targets:
        require(isinstance(entry, dict), "invalid TunaOS snapshot target")
        key = entry.get("targetKey")
        target, availability, publication = (entry.get(name) for name in ("target", "availability", "publication"))
        require(isinstance(key, str) and all(isinstance(value, dict) for value in (target, availability, publication)),
                f"incomplete TunaOS snapshot target {key!r}")
        flavor = target.get("flavor")
        require(isinstance(flavor, str) and flavor and isinstance(target.get("variant"), str),
                f"TunaOS snapshot target {key!r} needs a variant and flavor")
        if (target.get("platform") != "linux/amd64" or availability.get("available") is not True
                or target.get("hardwareScope") != "generic" or hardware_specific(flavor)):
            continue
        ref = publication.get("ref")
        require(valid_ref(ref) and ref.startswith(TUNAOS_REPOSITORY_PREFIX)
                and ref == f"{publication.get('repository')}:{publication.get('tag')}",
                f"invalid publication for TunaOS snapshot target {key!r}")
        require(ref not in refs, f"duplicate TunaOS snapshot publication {ref}")
        refs.add(ref)
        candidates.append({"targetKey": key, "imageRef": ref, "backend": snapshot_backend(entry.get("facts"))})
    require(candidates, "TunaOS snapshot has no generic linux/amd64 candidates")
    return candidates


def tunaos_catalog(candidates, entries):
    """Proven-only: a TunaOS candidate is shown only with a passing wootc run.

    The backend is the reviewed one (bootc-migrate source or explicit local
    policy). A snapshot backend fact, when present, must agree with it.
    """
    by_ref = {candidate["imageRef"]: candidate for candidate in candidates}
    shown = []
    for image, backend, evidence in entries:
        if evidence is None or not image["imageRef"].startswith(TUNAOS_REPOSITORY_PREFIX):
            continue
        candidate = by_ref.get(image["imageRef"])
        require(candidate is not None,
                f"{image['id']}: proven image is not a generic amd64 target of the TunaOS snapshot")
        require(candidate["backend"] in (None, backend),
                f"{image['id']}: snapshot backend {candidate['backend']} conflicts with reviewed backend {backend}")
        shown.append(image)
    require(shown, "no TunaOS snapshot candidate has a passing wootc install run")
    return shown


def render(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def snapshot_pin(raw):
    snapshot = json.loads(raw)
    require(isinstance(snapshot, dict) and isinstance(snapshot.get("generatedAt"), str)
            and re.fullmatch(r"sha256:[0-9a-f]{64}", str(snapshot.get("snapshotDigest"))),
            "TunaOS snapshot needs generatedAt and snapshotDigest")
    return {"url": SNAPSHOT_URL, "generatedAt": snapshot["generatedAt"],
            "snapshotDigest": snapshot["snapshotDigest"], "sha256": hashlib.sha256(raw).hexdigest()}


def validate_provenance(provenance, raw, snapshot_raw):
    keys = ("repository", "revision", "path", "sha256", "tunaosSnapshot")
    fields(provenance, keys, keys, "provenance")
    require(provenance["tunaosSnapshot"] == snapshot_pin(snapshot_raw),
            "TunaOS snapshot drifted from its pinned generatedAt, digest or hash")
    require(provenance["repository"] == REPOSITORY and provenance["path"] == SOURCE_PATH,
            "unexpected catalog source provenance")
    require(isinstance(provenance["revision"], str)
            and re.fullmatch(r"[0-9a-f]{40}", provenance["revision"]),
            "catalog revision must be a full immutable commit")
    require(provenance["sha256"] == hashlib.sha256(raw).hexdigest(),
            "reviewed source snapshot hash drift")


def fetch(url):
    # iso.tunaos.org refuses urllib's default User-Agent with 403.
    with urlopen(Request(url, headers={"User-Agent": "wootc-catalog-sync"}), timeout=30) as response:
        return response.read()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="offline drift check; never write files")
    mode.add_argument("--revision", help="fetch exact reviewed upstream commit and regenerate")
    mode.add_argument("--snapshot", action="store_true", help="fetch and pin the current TunaOS catalog snapshot")
    mode.add_argument("--candidates", action="store_true", help="list TunaOS candidates and their wootc proof")
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    data = args.root / "app/data"
    brand_path = args.root / TUNAOS_BRAND_CATALOG
    provenance = json.loads((data / "catalog-provenance.json").read_bytes())
    if args.revision is not None:
        require(re.fullmatch(r"[0-9a-f]{40}", args.revision), "--revision requires a full immutable commit")
        raw = fetch(f"https://raw.githubusercontent.com/tuna-os/bootc-migrate/{args.revision}/{SOURCE_PATH}")
        provenance.update(repository=REPOSITORY, revision=args.revision,
                          path=SOURCE_PATH, sha256=hashlib.sha256(raw).hexdigest())
    else:
        raw = (data / "catalog-sources.json").read_bytes()
    if args.snapshot:
        snapshot_raw = fetch(SNAPSHOT_URL)
        provenance["tunaosSnapshot"] = snapshot_pin(snapshot_raw)
    else:
        snapshot_raw = (data / SNAPSHOT_FILE).read_bytes()
    validate_provenance(provenance, raw, snapshot_raw)
    policy = json.loads((data / "catalog-policy.json").read_bytes())
    entries = resolve_entries(json.loads(raw), policy)
    candidates = snapshot_candidates(json.loads(snapshot_raw))
    generated = render([image for image, _, _ in entries])
    brand = render(tunaos_catalog(candidates, entries))
    if args.candidates:
        proof = {image["imageRef"]: evidence["run"] for image, _, evidence in entries if evidence}
        for candidate in candidates:
            run = proof.get(candidate["imageRef"])
            print("\t".join((candidate["targetKey"], candidate["imageRef"], candidate["backend"] or "unknown",
                             f"proven:{run}" if run else "unproven")))
    elif args.check:
        require((data / "images.json").read_bytes() == generated,
                "generated images.json drift; run python3 app/catalog_sync.py and review the diff")
        require(brand_path.read_bytes() == brand,
                f"generated {TUNAOS_BRAND_CATALOG} drift; run python3 app/catalog_sync.py and review the diff")
        print(f"Reviewed catalog synchronized at {provenance['revision']}; "
              f"TunaOS snapshot {provenance['tunaosSnapshot']['generatedAt']}")
    else:
        # Resolve everything before changing any file: unsupported schemas and
        # changed backend/boot policy fail without modifying the reviewed pin.
        if args.revision is not None:
            (data / "catalog-sources.json").write_bytes(raw)
        if args.snapshot:
            (data / SNAPSHOT_FILE).write_bytes(snapshot_raw)
        if args.revision is not None or args.snapshot:
            (data / "catalog-provenance.json").write_bytes(render(provenance))
        (data / "images.json").write_bytes(generated)
        brand_path.write_bytes(brand)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"catalog: {error}", file=sys.stderr)
        sys.exit(1)
