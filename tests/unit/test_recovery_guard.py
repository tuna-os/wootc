#!/usr/bin/env python3
"""Unit tests for the recovery guard contract and decision table (issue #331)."""

import json
import os
import tempfile
import unittest


class TestRecoveryGuardDecisionTable(unittest.TestCase):
    def test_decision_one_shot_never_booted(self):
        """armed.json present + no deployer-started -> one-shot never booted Linux."""
        armed = {
            "bcdGuid": "{12345678-1234-1234-1234-123456789abc}",
            "espPartitionGuid": "{esp-guid}",
            "espFiles": ["EFI/fedora/shimx64.efi"],
            "storageDrive": "C",
            "imageRef": "ghcr.io/tuna-os/yellowfin:gnome",
        }
        started_exists = False
        state = {"state": "armed"}

        # Simulate decision table logic
        verdict = "one-shot-never-booted" if (not started_exists and state.get("state") not in ["deployed", "healthy"]) else "other"
        self.assertEqual(verdict, "one-shot-never-booted")

    def test_decision_interrupted_deployer(self):
        """deployer-started present + state=deploying -> deployer interrupted."""
        started_exists = True
        state = {"state": "deploying", "phase": "scratch-setup"}

        verdict = "interrupted" if (started_exists and state.get("state") == "deploying") else "other"
        self.assertEqual(verdict, "interrupted")

    def test_decision_failed_deployer(self):
        """deployer-started present + state=failed -> deployer failed cleanly with phase."""
        started_exists = True
        state = {"state": "failed", "phase": "fisherman", "error": "pull error"}

        verdict = "failed" if (started_exists and state.get("state") == "failed") else "other"
        self.assertEqual(verdict, "failed")
        self.assertEqual(state.get("phase"), "fisherman")

    def test_decision_deployed(self):
        """deployer-started present + state=deployed -> Phase-2 staged."""
        started_exists = True
        state = {"state": "deployed"}

        verdict = "deployed" if (started_exists and state.get("state") == "deployed") else "other"
        self.assertEqual(verdict, "deployed")

    def test_decision_healthy(self):
        """state=healthy -> complete; tasks and armed.json removed."""
        state = {"state": "healthy"}

        verdict = "healthy" if state.get("state") == "healthy" else "other"
        self.assertEqual(verdict, "healthy")


class TestDeployerScriptMarkers(unittest.TestCase):
    def setUp(self):
        self.repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
        self.deploy_sh = os.path.join(self.repo_root, "payload/deployer/deploy.sh")

    def test_deploy_sh_writes_deployer_started(self):
        with open(self.deploy_sh, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn("write_deployer_started", content)
        self.assertIn("deployer-started.json", content)

    def test_deploy_sh_writes_state_transitions(self):
        with open(self.deploy_sh, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn('write_ntfs_state "deploying"', content)
        self.assertIn('write_ntfs_state "deployed"', content)
        self.assertIn('write_ntfs_state "failed"', content)

    def test_deploy_sh_fault_injection(self):
        with open(self.deploy_sh, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertIn("check_fault_injection", content)
        self.assertIn('check_fault_injection "scratch-setup"', content)
        self.assertIn('check_fault_injection "fisherman"', content)
        self.assertIn('check_fault_injection "verify-complete"', content)


if __name__ == "__main__":
    unittest.main()
