//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// ── Volumes, partitions and the root.disk image ───────────────────────────────

func defragRecommended(vol string) bool {
	out, _ := runCmd("defrag.exe", vol, "/A", "/V")
	return strings.Contains(strings.ToLower(out), "you should defragment this volume")
}

func defragDrive() error {
	out, err := runCmd("defrag.exe", `C:`, "/U", "/V")
	if err != nil {
		return fmt.Errorf("defragmenting C:: %w (output: %s)", err, strings.TrimSpace(out))
	}
	return nil
}

// listDataPartitions enumerates fixed volumes other than C: with their
// free space and encryption state, as candidates for root.disk when C:
// is BitLocker-protected (SPEC §3.5 manual path).
func listDataPartitions() []DataPartition {
	out, err := runPowerShellOutput(
		`Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.DriveLetter -ne 'C' } | ` +
			`ForEach-Object { $b = (Get-BitLockerVolume -MountPoint ($_.DriveLetter + ':') -ErrorAction SilentlyContinue); ` +
			`'{0}|{1}|{2}|{3}' -f $_.DriveLetter, $_.FileSystemLabel, [math]::Round($_.SizeRemaining/1GB,1), ` +
			`($(if ($b -and $b.ProtectionStatus -eq 'On') {'1'} else {'0'})) }`)
	if err != nil {
		return nil
	}
	var parts []DataPartition
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		f := strings.Split(strings.TrimSpace(line), "|")
		if len(f) != 4 || f[0] == "" {
			continue
		}
		free, _ := strconv.ParseFloat(f[2], 64)
		parts = append(parts, DataPartition{
			Letter: f[0], Label: f[1], FreeGB: free, Encrypted: f[3] == "1",
		})
	}
	return parts
}

// dedicatedVolumeInfo reports whether drive d holds only wootc data (so it
// is safe to remove and fold back into C:) and how much space that frees.
// It verifies ownership and ensures system/EFI volumes or arbitrary drives
// are never identified as wootc-created data partitions.
func dedicatedVolumeInfo(d string) (bool, float64) {
	receipt, err := readStoragePartitionReceipt()
	if err != nil {
		return false, 0
	}
	size, err := assessCreatedPartition(strings.ToUpper(d), receipt)
	return err == nil, size
}

// CreateDataPartition shrinks C: and creates a new unencrypted NTFS
// partition of sizeGB for Linux storage, returning its drive letter.
// C: stays BitLocker-protected — the new volume is created outside the
// encrypted region and holds only root.disk + vault (SPEC §3.5). We never
// decrypt C:. Suspend-BitLocker (RebootCount 1) only relaxes the TPM seal
// so the partition table can be edited; the disk stays encrypted and
// protection auto-resumes on next boot.
func (a *App) CreateDataPartition(sizeGB int) (DataPartition, error) {
	if sizeGB < 20 {
		sizeGB = 20
	}
	receiptPath, err := storagePartitionReceiptPath(true)
	if err != nil {
		return DataPartition{}, fmt.Errorf("prepare partition ownership receipt: %w", err)
	}
	if _, err := os.Lstat(receiptPath); err == nil {
		return DataPartition{}, fmt.Errorf("an existing partition creation receipt must be resolved before creating another partition")
	} else if !os.IsNotExist(err) {
		return DataPartition{}, err
	}
	// Reserve before touching storage. Any interrupted creation remains blocked
	// for explicit inspection; absence of a receipt never authorizes deletion.
	pendingPath := receiptPath + ".pending"
	pending, err := os.OpenFile(pendingPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return DataPartition{}, fmt.Errorf("partition creation is already pending or its authority cannot be reserved: %w", err)
	}
	if _, err := pending.WriteString("creation-pending\n"); err != nil {
		_ = pending.Close()
		return DataPartition{}, err
	}
	if err := pending.Sync(); err != nil {
		_ = pending.Close()
		return DataPartition{}, err
	}
	if err := pending.Close(); err != nil {
		return DataPartition{}, err
	}
	script := partitionPolicyScript + fmt.Sprintf(`
$ErrorActionPreference = 'Stop'
$sources = @(Get-Partition -DriveLetter C -ErrorAction Stop)
if ($sources.Count -ne 1 -or $sources[0].IsBoot -ne $true) { throw 'Windows source partition is missing or ambiguous' }
$c = $sources[0]
$originalSourceGuid = Convert-WootcPartitionGuid $c.Guid
$disks = @(Get-Disk -Number $c.DiskNumber -ErrorAction Stop)
if ($disks.Count -ne 1 -or $disks[0].PartitionStyle -ne 'GPT') { throw 'Windows source GPT disk is missing or ambiguous' }
$originalDiskGuid = Convert-WootcPartitionGuid $disks[0].Guid
$bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
if ($bl -and $bl.ProtectionStatus -eq 'On') { Suspend-BitLocker -MountPoint 'C:' -RebootCount 1 | Out-Null }
$supported = Get-PartitionSupportedSize -DriveLetter C
$shrinkBytes = %dGB
$target = $supported.SizeMax - $shrinkBytes
if ($target -lt $supported.SizeMin) { throw 'Not enough free space on C: to shrink by the requested amount' }
Resize-Partition -DriveLetter C -Size $target
$np = New-Partition -DiskNumber $c.DiskNumber -UseMaximumSize -AssignDriveLetter
$createdGuid = Convert-WootcPartitionGuid $np.Guid
Format-Volume -Partition $np -FileSystem NTFS -NewFileSystemLabel 'wootc-data' -Confirm:$false | Out-Null
$np = Get-Partition -DiskNumber $c.DiskNumber -PartitionNumber $np.PartitionNumber
if ((Convert-WootcPartitionGuid $np.Guid) -ne $createdGuid) { throw 'Created partition identity changed during formatting' }
if ((Convert-WootcPartitionGuid $c.Guid) -ne $originalSourceGuid) { throw 'Original Windows source identity changed' }
# This is the new, dedicated volume only. Prevent DELETE_CHILD on its root
# from bypassing the protected ACL on the installer directory below it.
$volumeRoot = "$($np.DriveLetter):" + [IO.Path]::DirectorySeparatorChar
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
Set-Acl -LiteralPath $volumeRoot -AclObject $acl
$receipt = New-WootcPartitionCreationReceipt -CreatedPartition $np -SourcePartition $c -SourceDiskGuid $originalDiskGuid
[pscustomobject]@{letter=[string]$np.DriveLetter;receipt=$receipt} | ConvertTo-Json -Compress`, sizeGB)

	out, err := runPowerShellOutput(script)
	if err != nil {
		return DataPartition{}, fmt.Errorf("create data partition: %w (output: %s)", err, strings.TrimSpace(out))
	}
	var result struct {
		Letter  string                  `json:"letter"`
		Receipt StoragePartitionReceipt `json:"receipt"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &result); err != nil {
		return DataPartition{}, fmt.Errorf("created partition ownership was not returned; pending receipt retained: %w", err)
	}
	if len(result.Letter) != 1 || result.Letter[0] < 'A' || result.Letter[0] > 'Z' || result.Letter == "C" {
		return DataPartition{}, fmt.Errorf("created partition lacks a valid dedicated drive letter")
	}
	if err := persistNewStoragePartitionReceipt(receiptPath, result.Receipt); err != nil {
		return DataPartition{}, fmt.Errorf("partition created but ownership persistence failed; partition preserved: %w", err)
	}
	if err := os.Remove(pendingPath); err != nil {
		return DataPartition{}, fmt.Errorf("creation receipt saved but pending marker cleanup failed: %w", err)
	}
	return DataPartition{Letter: result.Letter, Label: "wootc-data", FreeGB: float64(result.Receipt.SizeBytes) / (1024 * 1024 * 1024), Encrypted: false}, nil
}

// removePartitionAndExtendC deletes the wootc data partition and grows C:
// into the freed space (SPEC §5.2). Only called when the volume is
// confirmed wootc-created and holds no other data.
func removePartitionAndExtendC(drive string, receipt StoragePartitionReceipt) error {
	if err := verifyStoragePartitionRemoval(receipt); err != nil {
		return fmt.Errorf("explicit removal receipt required: %w", err)
	}
	declaration, err := partitionReceiptPowerShell(receipt)
	if err != nil {
		return err
	}
	if drive != "" && (len(drive) != 1 || drive[0] < 'A' || drive[0] > 'Z' || drive == "C") {
		return fmt.Errorf("invalid partition removal drive")
	}
	// A request/intent is not proof of deletion. Persist a second receipt only
	// after the actual helper has positively observed the bound GUID disappear.
	if err := verifyPartitionRemovalMarker(receipt, ".deleted"); err != nil {
		if !os.IsNotExist(err) {
			return fmt.Errorf("deletion receipt is unsafe or mismatched: %w", err)
		}
		out, removalErr := runPowerShellOutput(partitionPolicyScript + "\n" + declaration + "Remove-WootcCreatedPartition -Drive '" + drive + "' -Receipt $receipt -ExplicitRemoval -DeferExtension")
		if removalErr != nil {
			return fmt.Errorf("partition deletion not verified: %w (output: %s)", removalErr, strings.TrimSpace(out))
		}
		if strings.TrimSpace(out) != "partition-removal-observed" {
			return fmt.Errorf("partition deletion was not positively observed")
		}
		path, err := storagePartitionReceiptPath(false)
		if err != nil {
			return err
		}
		if err := persistNewStoragePartitionReceipt(path+".deleted", receipt); err != nil {
			return fmt.Errorf("partition deleted but durable deletion observation could not be retained: %w", err)
		}
	}
	out, err := runPowerShellOutput(partitionPolicyScript + "\n" + declaration + "Remove-WootcCreatedPartition -Drive '' -Receipt $receipt -ExplicitRemoval -AllowExtensionRetry")
	if err != nil {
		return fmt.Errorf("%w (output: %s)", err, strings.TrimSpace(out))
	}
	if strings.TrimSpace(out) != "partition-removal-and-extension-verified" {
		return fmt.Errorf("partition deletion and Windows extension were not positively observed")
	}

	return nil
}

// ── Raw root.disk creation ────────────────────────────────────────────────────

// createRootDisk creates the RAW root.disk image the deployer partitions and
// Phase 2 attaches with `losetup --partscan`. Raw replaced VHDX in 8136ae6:
// target bootc images ship losetup but not qemu-nbd, so VHDX forced a
// foreign qemu-nbd + 26-library closure into the Phase-2 initramfs (soname
// mismatches, silent staging deaths, QEMU VHDX-corruption reports). This
// function had not been ported and still made a VHDX no Phase 2 could
// attach (found by the GUI-driven E2E, run 20260723T1144).
//
// Two Windows-specific requirements, mirrored from setup-wootc.ps1:
//   - allocate with SetLength (sparse on NTFS, instant), and
//   - extend the Valid Data Length with `fsutil file setvaliddata` —
//     without it the Linux ntfs3 driver EIOs on every loop0 write past VDL.
func requireNewInstallRootDisk() error {
	return requireNewRootDiskPath(filepath.Join(wootcDir(), "disks", "root.disk"))
}

func createRootDisk(sizeGB int) error {
	if sizeGB <= 0 || int64(sizeGB) > (int64(1<<63-1)/(1024*1024*1024)) {
		return fmt.Errorf("root.disk size is invalid")
	}
	path := filepath.Join(wootcDir(), "disks", "root.disk")
	sizeBytes := int64(sizeGB) * 1024 * 1024 * 1024
	return allocateNewRootDiskFile(path, sizeBytes, func(path string) error {
		if out, err := runCmd("fsutil", "file", "setvaliddata", path, fmt.Sprintf("%d", sizeBytes)); err != nil {
			return fmt.Errorf("fsutil setvaliddata (VDL extension): %w: %s", err, strings.TrimSpace(out))
		}
		return nil
	})
}
