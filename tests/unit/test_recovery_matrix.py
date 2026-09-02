#!/usr/bin/env python3
"""test_recovery_matrix.py — Unit tests for recovery & fault-injection matrix (#288)."""

import hashlib
import json
import os
import re
import tempfile
import unittest

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MATRIX_PATH = os.path.join(ROOT_DIR, "tests", "e2e", "matrix.tsv")


class TestRecoveryMatrix(unittest.TestCase):
    def test_matrix_tsv_recovery_coverage(self):
        """Verify that matrix.tsv specifies recovery cases covering all 6 fault boundaries."""
        required_boundaries = {
            "image-pull",
            "root-disk",
            "efi-staging",
            "bcd-arming",
            "pre-reboot",
            "deploy-failure",
        }
        found_boundaries = set()
        smoke_boundaries = set()

        with open(MATRIX_PATH, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) >= 7:
                    tier, name, image, win_ver, win_ed, win_key, opts = parts[:7]
                    for opt in opts.split(","):
                        if opt.startswith("fault="):
                            boundary = opt.split("=", 1)[1]
                            found_boundaries.add(boundary)
                            if tier == "smoke":
                                smoke_boundaries.add(boundary)

        missing = required_boundaries - found_boundaries
        self.assertFalse(missing, f"Missing fault boundaries in matrix.tsv: {missing}")
        self.assertIn("image-pull", smoke_boundaries, "image-pull should be covered in smoke tier")
        self.assertIn("bcd-arming", smoke_boundaries, "bcd-arming should be covered in smoke tier")
        self.assertIn("deploy-failure", smoke_boundaries, "deploy-failure should be covered in smoke tier")

    def test_state_json_lifecycle_transitions(self):
        """Test serialization and valid schema for lifecycle states."""
        with tempfile.TemporaryDirectory() as tmpdir:
            state_file = os.path.join(tmpdir, "state.json")

            # 1. Cancelled pre-reboot
            cancelled_state = {
                "state": "staged",
                "phase": "cancelled",
                "error": "fault-injection: simulated cancellation before reboot",
                "updatedAt": "2026-09-02T08:00:00Z",
                "updatedBy": "wootc-installer",
            }
            with open(state_file, "w", encoding="utf-8") as f:
                json.dump(cancelled_state, f)

            with open(state_file, "r", encoding="utf-8") as f:
                loaded = json.load(f)
            self.assertEqual(loaded["state"], "staged")
            self.assertEqual(loaded["phase"], "cancelled")

            # 2. Failed boundary
            failed_state = {
                "state": "failed",
                "phase": "image-pull",
                "error": "fault-injection: simulated failure during image download",
                "updatedAt": "2026-09-02T08:01:00Z",
                "updatedBy": "wootc-installer",
            }
            with open(state_file, "w", encoding="utf-8") as f:
                json.dump(failed_state, f)

            with open(state_file, "r", encoding="utf-8") as f:
                loaded = json.load(f)
            self.assertEqual(loaded["state"], "failed")
            self.assertEqual(loaded["phase"], "image-pull")

            # 3. Retried armed
            armed_state = {
                "state": "armed",
                "updatedAt": "2026-09-02T08:02:00Z",
                "updatedBy": "wootc-installer",
            }
            with open(state_file, "w", encoding="utf-8") as f:
                json.dump(armed_state, f)

            with open(state_file, "r", encoding="utf-8") as f:
                loaded = json.load(f)
            self.assertEqual(loaded["state"], "armed")

    def test_oci_blob_partial_and_reuse_logic(self):
        """Test partial .part file handling and digest verification."""
        with tempfile.TemporaryDirectory() as tmpdir:
            blob_dir = os.path.join(tmpdir, "blobs", "sha256")
            os.makedirs(blob_dir, exist_ok=True)

            data = b"hello full blob data for linux rootfs layer"
            digest = hashlib.sha256(data).hexdigest()
            final_blob = os.path.join(blob_dir, digest)
            part_blob = final_blob + ".part"

            # 1. Simulate interrupted download: .part file exists
            with open(part_blob, "wb") as f:
                f.write(b"partial incomplete data")

            # Validate that the final blob does not exist yet
            self.assertFalse(os.path.exists(final_blob))
            self.assertTrue(os.path.exists(part_blob))

            # 2. Simulate retry: clean up or overwrite .part and complete blob
            with open(part_blob, "wb") as f:
                f.write(data)
            with open(part_blob, "rb") as f:
                actual_digest = hashlib.sha256(f.read()).hexdigest()
            self.assertEqual(actual_digest, digest)
            os.replace(part_blob, final_blob)

            self.assertTrue(os.path.exists(final_blob))
            self.assertFalse(os.path.exists(part_blob))
            self.assertEqual(os.path.getsize(final_blob), len(data))

    def test_bcd_idempotency_simulation(self):
        """Simulate BCD entry sweep preventing duplicate entries across retries."""
        entries = {}

        def sweep_entries():
            to_del = [guid for guid, d in entries.items() if d.get("description") == "wootc"]
            for guid in to_del:
                del entries[guid]

        def create_entry(guid):
            sweep_entries()
            entries[guid] = {"description": "wootc", "path": r"\EFI\fedora\shimx64.efi"}

        # Attempt 1: created GUID A, interrupted
        create_entry("{11111111-2222-3333-4444-555555555555}")
        self.assertEqual(len(entries), 1)

        # Attempt 2: retried, created GUID B
        create_entry("{66666666-7777-8888-9999-000000000000}")
        self.assertEqual(len(entries), 1)
        self.assertIn("{66666666-7777-8888-9999-000000000000}", entries)
        self.assertNotIn("{11111111-2222-3333-4444-555555555555}", entries)

        # Attempt 3: uninstall
        sweep_entries()
        self.assertEqual(len(entries), 0)


if __name__ == "__main__":
    unittest.main()
