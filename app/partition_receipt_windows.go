//go:build windows

package main

import (
	_ "embed"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

//go:embed partition-policy.ps1
var partitionPolicyScript string

// Keep ownership receipts outside the installer tree. A failed uninstall must
// never erase the only authority required to retry a partition removal.
func partitionReceiptDirectory() (string, error) {
	base, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, 0)
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "wootc-partition-receipts"), nil
}

func inspectPartitionReceiptParents(dir string) error {
	volume := filepath.VolumeName(dir)
	if len(volume) != 2 || volume[1] != ':' {
		return fmt.Errorf("partition receipt requires a local fixed volume")
	}
	p, err := windows.UTF16PtrFromString(volume + `\`)
	if err != nil {
		return err
	}
	if windows.GetDriveType(p) != windows.DRIVE_FIXED {
		return fmt.Errorf("partition receipt requires a fixed volume")
	}
	if err := inspectStateObject(volume+`\`, true); err != nil {
		return err
	}
	return inspectStateObject(filepath.Dir(dir), true)
}

func storagePartitionReceiptPath(create bool) (string, error) {
	dir, err := partitionReceiptDirectory()
	if err != nil {
		return "", err
	}
	if err := inspectPartitionReceiptParents(dir); err != nil {
		return "", err
	}
	if create {
		if err := prepareTrustedStateTree(dir); err != nil {
			return "", err
		}
	} else if err := inspectStateObject(dir, false); err != nil {
		return "", err
	}
	return filepath.Join(dir, "creation.json"), nil
}

func readStoragePartitionReceipt() (StoragePartitionReceipt, error) {
	path, err := storagePartitionReceiptPath(false)
	if err != nil {
		return StoragePartitionReceipt{}, err
	}
	receipt, err := readPartitionReceiptFile(path)
	if os.IsNotExist(err) {
		return readPartitionReceiptFile(path + ".complete")
	}
	return receipt, err
}

func readPartitionReceiptFile(path string) (StoragePartitionReceipt, error) {
	if err := inspectStateObject(path, false); err != nil {
		return StoragePartitionReceipt{}, err
	}
	f, err := os.Open(path)
	if err != nil {
		return StoragePartitionReceipt{}, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		return StoragePartitionReceipt{}, fmt.Errorf("partition receipt is not a regular file")
	}
	data, err := io.ReadAll(io.LimitReader(f, 4097))
	if err != nil {
		return StoragePartitionReceipt{}, err
	}
	return decodeStoragePartitionReceipt(data)
}

func assessCreatedPartition(drive string, receipt StoragePartitionReceipt) (float64, error) {
	if len(drive) != 1 || drive[0] < 'A' || drive[0] > 'Z' || drive == "C" {
		return 0, fmt.Errorf("invalid dedicated storage drive")
	}
	declaration, err := partitionReceiptPowerShell(receipt)
	if err != nil {
		return 0, err
	}
	out, err := runPowerShellOutput(partitionPolicyScript + "\n" + declaration + "$binding = Get-WootcPartitionRemovalBinding -Drive '" + drive + "' -Receipt $receipt\nWrite-Output 'partition-removal-assessment-verified'")
	if err != nil {
		return 0, fmt.Errorf("partition removal assessment refused: %w (output: %s)", err, strings.TrimSpace(out))
	}
	if strings.TrimSpace(out) != "partition-removal-assessment-verified" {
		return 0, fmt.Errorf("partition removal assessment was not positively confirmed")
	}
	return float64(receipt.SizeBytes) / (1024 * 1024 * 1024), nil
}

// The immutable creation receipt remains intact. A separate, equally protected
// receipt records explicit removal intent before any uninstall file deletion.
func markStoragePartitionRemoval(receipt StoragePartitionReceipt) error {
	path, err := storagePartitionReceiptPath(false)
	if err != nil {
		return err
	}
	marker := path + ".removal"
	if _, err := os.Lstat(marker); err == nil {
		return verifyStoragePartitionRemoval(receipt)
	} else if !os.IsNotExist(err) {
		return err
	}
	return persistNewStoragePartitionReceipt(marker, receipt)
}

func verifyStoragePartitionRemoval(receipt StoragePartitionReceipt) error {
	return verifyPartitionRemovalMarker(receipt, ".removal")
}

func verifyPartitionRemovalMarker(receipt StoragePartitionReceipt, suffix string) error {
	path, err := storagePartitionReceiptPath(false)
	if err != nil {
		return err
	}
	marker := path + suffix
	if err := inspectStateObject(marker, false); err != nil {
		return err
	}
	f, err := os.Open(marker)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		return fmt.Errorf("removal receipt is not a regular file")
	}
	data, err := io.ReadAll(io.LimitReader(f, 4097))
	if err != nil {
		return err
	}
	recorded, err := decodeStoragePartitionReceipt(data)
	if err != nil {
		return err
	}
	if recorded != receipt {
		return fmt.Errorf("removal receipt does not match creation identity")
	}
	return nil
}

func createdPartitionLocation(receipt StoragePartitionReceipt) (string, bool, error) {
	declaration, err := partitionReceiptPowerShell(receipt)
	if err != nil {
		return "", false, err
	}
	out, err := runPowerShellOutput(partitionPolicyScript + "\n" + declaration + `
 $location = Get-WootcCreatedPartitionLocation -Receipt $receipt
 if ($null -eq $location.Partition) { Write-Output 'ABSENT' } else {
 $letter = [string]$location.Partition.DriveLetter
 if ($letter -notmatch '^[A-Z]$' -or $letter -eq 'C') { throw 'Created partition lacks a safe drive letter' }
 Write-Output "PRESENT:$letter"
 }`)
	if err != nil {
		return "", false, fmt.Errorf("locating created partition: %w (output: %s)", err, strings.TrimSpace(out))
	}
	out = strings.TrimSpace(out)
	if out == "ABSENT" {
		return "", false, nil
	}
	if len(out) == 9 && strings.HasPrefix(out, "PRESENT:") {
		return out[8:], true, nil
	}
	return "", false, fmt.Errorf("created partition location was not positively observed")
}

func verifyCompanionInstallerContents() error {
	path := `C:\wootc`
	if _, err := os.Lstat(path); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	out, err := runPowerShellOutput(partitionPolicyScript + "\nAssert-WootcPartitionContents -Drive C -InstallerTreeOnly\nWrite-Output 'companion-contents-verified'")
	if err != nil {
		return fmt.Errorf("preserving unverified companion installer files: %w (output: %s)", err, strings.TrimSpace(out))
	}
	if strings.TrimSpace(out) != "companion-contents-verified" {
		return fmt.Errorf("companion contents were not positively verified")
	}
	return nil
}

func cleanupCompanionInstallerFiles() error {
	if _, err := os.Lstat(`C:\wootc`); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	out, err := runPowerShellOutput(partitionPolicyScript + "\nRemove-WootcInstallerFiles -Root C:/")
	if err != nil {
		return fmt.Errorf("companion file cleanup incomplete: %w (output: %s)", err, strings.TrimSpace(out))
	}
	if strings.TrimSpace(out) != "companion-cleanup-verified" {
		return fmt.Errorf("companion cleanup was not positively observed")
	}
	return nil
}

func clearCompletedStoragePartitionRemoval(receipt StoragePartitionReceipt) error {
	path, err := storagePartitionReceiptPath(false)
	if err != nil {
		return err
	}
	return finalizeStoragePartitionRemoval(path, receipt, readPartitionReceiptFile, os.Remove)
}

func fillDedicatedPartitionInfo(info *UninstallInfo, drive string) {
	receipt, err := readStoragePartitionReceipt()
	if err == nil {
		info.ReclaimGB, err = assessCreatedPartition(drive, receipt)
	}
	info.OnDedicatedVol = err == nil
	if err != nil {
		info.PartitionRemovalReason = "Partition preserved: its creation identity and complete file ownership could not be verified. " + err.Error()
	}
}
