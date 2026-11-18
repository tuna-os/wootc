#!/usr/bin/env python3
"""Contract tests for the catalog-to-E2E matrix coverage check."""
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location(
    "matrix_contract", ROOT / "e2e/validate-matrix.py"
)
contract = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(contract)

KEY = "W269N-WFGWX-YVC9B-4J6C9-T83GX"


def rows(text):
    parsed, errors = contract.parse_matrix(text)
    if errors:
        raise AssertionError(errors)
    return parsed


class MatrixContract(unittest.TestCase):
    def test_repository_matrix_covers_green_catalog(self):
        result = contract.validate(
            contract.load(ROOT.parent / "app/data/images.json"),
            rows((ROOT / "e2e/matrix.tsv").read_text(encoding="utf-8")),
        )
        self.assertEqual(result, [])

    def test_each_green_image_needs_both_pro_versions(self):
        catalog = [{"imageRef": "ghcr.io/example/green:stable", "status": "green"}]
        matrix = rows(
            f"full\twin11\tghcr.io/example/green:stable\t11\tpro\t{KEY}\n"
        )
        errors = contract.validate(catalog, matrix)
        self.assertEqual(
            errors,
            [
                "green image ghcr.io/example/green:stable has no ordinary Windows 10 Pro cell "
                "in the full-tier plan"
            ],
        )

    def test_axis_specific_rows_do_not_count_as_primary_coverage(self):
        catalog = [{"imageRef": "ghcr.io/example/green:stable", "status": "green"}]
        matrix = rows(
            "\n".join(
                [
                    f"full\twin10\tghcr.io/example/green:stable\t10\tpro\t{KEY}\tphase3=on",
                    f"full\twin11\tghcr.io/example/green:stable\t11\tpro\t{KEY}\tbitlocker=on",
                ]
            )
        )
        errors = contract.validate(catalog, matrix)
        self.assertEqual(len(errors), 2)
        self.assertTrue(all("ordinary Windows" in error for error in errors))

    def test_unknown_matrix_image_is_rejected(self):
        matrix = rows(f"full\tunknown\tghcr.io/example/missing:stable\t11\tpro\t{KEY}\n")
        errors = contract.validate([], matrix)
        self.assertIn(
            "matrix references image not present in app/data/images.json: "
            "ghcr.io/example/missing:stable",
            errors,
        )


if __name__ == "__main__":
    unittest.main()
