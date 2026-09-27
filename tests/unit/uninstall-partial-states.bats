#!/usr/bin/env bats
# uninstall-partial-states.bats — uninstall must converge from every partial-install state (#289).
#
# Interrupted installs can leave partial files, lifecycle markers, registry entries,
# power-setting changes, BCD entries, or EFI artifacts.
# The uninstaller must discover and converge cleanly from all partial states:
#   - fresh / unstarted
#   - staged (interrupted during download, root disk, or image pull)
#   - armed (interrupted after BCD / ESP staging)
#   - failed (failure recorded in state.json)
#   - partially deployed (deployer log or journal present)
#   - orphaned (C:\wootc deleted by hand)
#
# Dedicated volume cleanup must also strictly verify ownership and never confuse
# the EFI system partition with a wootc-created data partition.

INSTALLER_WIN=app/installer_windows.go
DISK_WIN=app/disk_windows.go
PARTITION_POLICY=app/partition-policy.ps1
HEADLESS_GO=app/headless.go
PROBE_WIN=app/sysprobe_windows.go

@test "getUninstallInfo detects partial install when wootc directory exists without root.disk" {
    grep -q 'Orphaned:\s*true' "$INSTALLER_WIN"
    grep -q 'hasWootcBCDEntry()' "$INSTALLER_WIN"
    grep -q 'hasWootcESPArtifacts()' "$INSTALLER_WIN"
    grep -q 'hasUninstallRegistryEntry()' "$INSTALLER_WIN"
}

@test "uninstallWith cleans up install, bundle, cache, and logs dirs on keep-root.disk" {
    grep -q 'os.RemoveAll(filepath.Join(wDir, sub))' "$INSTALLER_WIN"
    grep -q 'for _, sub := range \[\]string{"install", "bundle", "cache", "logs"}' "$INSTALLER_WIN"
}

@test "uninstallWith sweeps entire wootc folder when no root.disk exists or on deletion request" {
    grep -q 'opts.DeleteRootDisk || opts.RemovePartition || !rootDiskExists' "$INSTALLER_WIN"
}

@test "dedicated volume verification uses receipt policy and accepts only non-system basic NTFS partitions" {
    grep -q 'readStoragePartitionReceipt' "$DISK_WIN"
    grep -q "FileSystemLabel -ne 'wootc-data'" "$PARTITION_POLICY"
    grep -q "FileSystemType -ne 'NTFS'" "$PARTITION_POLICY"
    grep -q "GptType -ne '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'" "$PARTITION_POLICY"
    grep -q "Type -ne 'Basic'" "$PARTITION_POLICY"
    grep -q 'Remove-Partition -InputObject $binding.Partition' "$PARTITION_POLICY"
}

@test "partition reclaim refuses C and consumes only a receipt-bound target" {
    grep -q "\$Drive -eq 'C'" "$PARTITION_POLICY"
    grep -q 'partitionGuid' "$PARTITION_POLICY"
    grep -q 'sourceCPartitionGuid' "$PARTITION_POLICY"
}

@test "uninstall verifies clean convergence and reports leftover artifacts" {
    grep -q 'verifyUninstallClean' "$INSTALLER_WIN"
    grep -q 'uninstall cleanup incomplete' "$INSTALLER_WIN"
}

@test "headless uninstall command parses -delete-root-disk and -remove-partition flags" {
    grep -q 'headlessUninstall' "$HEADLESS_GO"
    grep -q 'delete-root-disk' "$HEADLESS_GO"
    grep -q 'remove-partition' "$HEADLESS_GO"
}
