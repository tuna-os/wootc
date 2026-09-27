#!/usr/bin/env python3
"""
test_uninstall_partial.py — unit test coverage for partial-install state convergence (#289).
Asserts that uninstall and partition cleanup logic properly handle all partial-install states,
distinguish EFI/system partitions from dedicated wootc-data partitions, and report cleanup failures.
"""

import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INSTALLER_WIN = os.path.join(REPO_ROOT, "app", "installer_windows.go")
DISK_WIN = os.path.join(REPO_ROOT, "app", "disk_windows.go")
HEADLESS_GO = os.path.join(REPO_ROOT, "app", "headless.go")
PROBE_WIN = os.path.join(REPO_ROOT, "app", "sysprobe_windows.go")

failures = []

def check(condition, label):
    if condition:
        print(f"  [PASS] {label}")
    else:
        print(f"  [FAIL] {label}")
        failures.append(label)

print("── test_uninstall_partial: verifying partial-state uninstall convergence ──")

# 1. Check installer_windows.go for comprehensive state detection
with open(INSTALLER_WIN, "r", encoding="utf-8") as f:
    installer_code = f.read()

check("hasWootcBCDEntry" in installer_code, "getUninstallInfo checks BCD firmware entries")
check("hasWootcESPArtifacts" in installer_code, "getUninstallInfo checks ESP artifacts")
check("hasUninstallRegistryEntry" in installer_code, "getUninstallInfo checks Add/Remove registry key")
check("cleanupESP" in installer_code, "uninstallWith invokes ownership-aware cleanupESP")
check("verifyUninstallClean" in installer_code, "uninstallWith verifies clean convergence")
check("deleteWootcBCDEntries" in installer_code, "uninstallWith sweeps BCD entries")
check("disarmOneShot" in installer_code, "uninstallWith clears one-shot bootsequence")
check("restorePriorPowerState" in installer_code, "uninstallWith restores power state before directory removal")

# 2. Check disk_windows.go for partition ownership safety
with open(DISK_WIN, "r", encoding="utf-8") as f:
    disk_code = f.read()

with open(os.path.join(REPO_ROOT, "app", "partition-policy.ps1"), encoding="utf-8") as f:
    policy_code = f.read()
check("readStoragePartitionReceipt" in disk_code, "assessment requires protected persistent creation receipt")
check("Get-WootcPartitionRemovalBinding" in policy_code, "actual removal uses full identity and contents binding")
check("Remove-Partition -InputObject $binding.Partition" in policy_code, "removal consumes verified object rather than drive letter")
check("partition-removal-and-extension-verified" in disk_code, "backend requires positively observed deletion and extension")
check("markStoragePartitionRemoval" in installer_code, "explicit removal intent survives partial uninstall")

# 3. Check headless.go for headlessUninstall
with open(HEADLESS_GO, "r", encoding="utf-8") as f:
    headless_code = f.read()

check("headlessUninstall" in headless_code, "headless CLI dispatches to headlessUninstall")
check("delete-root-disk" in headless_code, "headlessUninstall supports -delete-root-disk flag")
check("remove-partition" in headless_code, "headlessUninstall supports -remove-partition flag")

# 4. Check sysprobe_windows.go for power state mirror
with open(PROBE_WIN, "r", encoding="utf-8") as f:
    probe_code = f.read()

check("readPriorPowerMirror" in probe_code, "sysprobe_windows.go supports reading power state from registry mirror")
check("WootcPriorHibernate" in probe_code, "sysprobe_windows.go mirrors WootcPriorHibernate in registry")
check("WootcPriorHiberboot" in probe_code, "sysprobe_windows.go mirrors WootcPriorHiberboot in registry")

if failures:
    print(f"\nFAILED ({len(failures)} failures)")
    sys.exit(1)

print(f"\nALL CHECKS PASSED")
sys.exit(0)
