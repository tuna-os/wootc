#!/usr/bin/env python3
"""Validate that the hosted matrix covers every green catalog image.

The matrix is the evidence plan; catalog status is an output of that evidence.
This check therefore validates the plan without deriving it from catalog status.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

HOSTED_TIERS = {"smoke", "full"}
PRIMARY_EXCLUDED = (
    "bitlocker=",
    "fault=",
    "filesystem=",
    "firmware_db=",
    "offline=",
    "phase3=",
)


def parse_matrix(text: str) -> tuple[list[dict[str, object]], list[str]]:
    rows: list[dict[str, object]] = []
    errors: list[str] = []
    names: set[str] = set()

    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        if not raw_line.strip() or raw_line.startswith("#"):
            continue
        fields = raw_line.split("\t")
        if len(fields) < 6:
            errors.append(f"line {line_number}: expected at least 6 tab-separated fields")
            continue

        tier, name, image, win_version, win_edition, win_key = fields[:6]
        options = tuple(option for option in (fields[6] if len(fields) > 6 else "").split(",") if option)
        if tier not in HOSTED_TIERS:
            errors.append(f"line {line_number}: unsupported tier {tier!r}")
        if name in names:
            errors.append(f"line {line_number}: duplicate case name {name!r}")
        names.add(name)
        rows.append(
            {
                "line": line_number,
                "tier": tier,
                "name": name,
                "image": image,
                "win_version": win_version,
                "win_edition": win_edition,
                "win_key": win_key,
                "options": options,
            }
        )

    return rows, errors


def is_primary_pro_cell(row: dict[str, object], image: str, version: str) -> bool:
    options = row["options"]
    assert isinstance(options, tuple)
    return (
        row["tier"] in HOSTED_TIERS
        and row["image"] == image
        and row["win_version"] == version
        and row["win_edition"] == "pro"
        and not any(option.startswith(prefix) for option in options for prefix in PRIMARY_EXCLUDED)
    )


def validate(catalog: list[dict[str, object]], rows: list[dict[str, object]]) -> list[str]:
    """Return actionable contract violations for a catalog/matrix pair."""
    errors: list[str] = []
    catalog_refs: dict[str, dict[str, object]] = {}
    for entry in catalog:
        ref = entry.get("imageRef")
        if not isinstance(ref, str) or not ref:
            errors.append("catalog entry has no imageRef")
            continue
        if ref in catalog_refs:
            errors.append(f"catalog has duplicate imageRef {ref!r}")
        catalog_refs[ref] = entry

    matrix_refs = {row["image"] for row in rows}
    for ref in sorted(matrix_refs - catalog_refs.keys()):
        errors.append(f"matrix references image not present in app/data/images.json: {ref}")

    green_refs = sorted(
        ref for ref, entry in catalog_refs.items() if entry.get("status") == "green"
    )
    if not green_refs:
        errors.append("catalog has no green image entries")

    for ref in green_refs:
        for version in ("10", "11"):
            if not any(is_primary_pro_cell(row, ref, version) for row in rows):
                errors.append(
                    f"green image {ref} has no ordinary Windows {version} Pro cell "
                    "in the full-tier plan"
                )

    return errors


def load(path: Path) -> object:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--catalog", type=Path, default=Path("app/data/images.json"))
    parser.add_argument("--matrix", type=Path, default=Path("tests/e2e/matrix.tsv"))
    args = parser.parse_args(argv)

    rows, errors = parse_matrix(args.matrix.read_text(encoding="utf-8"))
    catalog = load(args.catalog)
    if not isinstance(catalog, list):
        errors.append(f"catalog root must be a JSON array: {args.catalog}")
    else:
        errors.extend(validate(catalog, rows))

    if errors:
        print("matrix contract failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"matrix contract passed: {len(rows)} hosted cases; green catalog images have Windows 10/11 Pro coverage")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
