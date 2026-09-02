//go:build windows

package main

import (
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
func dedicatedVolumeInfo(d string) (bool, float64) {
	// A wootc-created volume is labeled "wootc-data" and contains nothing
	// but the wootc dir (ignoring system folders) (#197, #225).
	out, err := runPowerShellOutput(fmt.Sprintf(
		`$items = @(Get-ChildItem '%s:\' -Force -ErrorAction SilentlyContinue | Where-Object { `+
			`$_.Name -notin @('$RECYCLE.BIN','System Volume Information','wootc') }); `+
			`$v = Get-Volume -DriveLetter %s -ErrorAction SilentlyContinue; `+
			`'{0}|{1}|{2}' -f $items.Count, [math]::Round($v.Size/1GB,1), $(if ($v) { $v.FileSystemLabel } else { '' })`, d, d))
	if err != nil {
		return false, 0
	}
	f := strings.Split(strings.TrimSpace(out), "|")
	if len(f) < 2 {
		return false, 0
	}
	label := ""
	if len(f) >= 3 {
		label = f[2]
	}
	sizeGB, _ := strconv.ParseFloat(f[1], 64)
	itemsCount, err := strconv.Atoi(strings.TrimSpace(f[0]))
	if err != nil {
		return false, 0
	}
	return isDedicatedVolume(itemsCount, label), sizeGB
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
	script := fmt.Sprintf(`
$ErrorActionPreference = 'Stop'
$c = Get-Partition -DriveLetter C
$bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
if ($bl -and $bl.ProtectionStatus -eq 'On') { Suspend-BitLocker -MountPoint 'C:' -RebootCount 1 | Out-Null }
$supported = Get-PartitionSupportedSize -DriveLetter C
$shrinkBytes = %dGB
$target = $supported.SizeMax - $shrinkBytes
if ($target -lt $supported.SizeMin) { throw 'Not enough free space on C: to shrink by the requested amount' }
Resize-Partition -DriveLetter C -Size $target
$np = New-Partition -DiskNumber $c.DiskNumber -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $np -FileSystem NTFS -NewFileSystemLabel 'wootc-data' -Confirm:$false | Out-Null
$np = Get-Partition -DiskNumber $c.DiskNumber -PartitionNumber $np.PartitionNumber
Write-Output $np.DriveLetter`, sizeGB)

	out, err := runPowerShellOutput(script)
	if err != nil {
		return DataPartition{}, fmt.Errorf("create data partition: %w (output: %s)", err, strings.TrimSpace(out))
	}
	letter := strings.TrimSpace(out)
	if len(letter) != 1 {
		return DataPartition{}, fmt.Errorf("unexpected drive letter from partition creation: %q", out)
	}
	return DataPartition{Letter: letter, Label: "wootc-data", FreeGB: float64(sizeGB), Encrypted: false}, nil
}

// removePartitionAndExtendC deletes the wootc data partition and grows C:
// into the freed space (SPEC §5.2). Only called when the volume is
// confirmed wootc-created and holds no other data.
func removePartitionAndExtendC(drive string) error {
	script := fmt.Sprintf(`
$ErrorActionPreference = 'Stop'
$v = Get-Volume -DriveLetter %s -ErrorAction SilentlyContinue
if (-not $v -or $v.FileSystemLabel -ne '%s') { throw "Partition %s: does not have the '%s' label" }
$p = Get-Partition -DriveLetter %s
Remove-Partition -DriveLetter %s -Confirm:$false
$supported = Get-PartitionSupportedSize -DriveLetter C
Resize-Partition -DriveLetter C -Size $supported.SizeMax`, drive, DedicatedVolumeLabel, drive, DedicatedVolumeLabel, drive, drive)
	out, err := runPowerShellOutput(script)
	if err != nil {
		return fmt.Errorf("%w (output: %s)", err, strings.TrimSpace(out))
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
func createRootDisk(sizeGB int) error {
	path := filepath.Join(wootcDir(), "disks", "root.disk")
	sizeBytes := int64(sizeGB) * 1024 * 1024 * 1024
	if st, err := os.Stat(path); err == nil && st.Size() == sizeBytes {
		return nil // already exists at the right size
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create disks dir: %w", err)
	}
	_ = os.Remove(path)

	f, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("create root.disk: %w", err)
	}
	if err := f.Truncate(sizeBytes); err != nil {
		_ = f.Close()
		return fmt.Errorf("allocate root.disk (%d GB): %w", sizeGB, err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("close root.disk: %w", err)
	}

	// setvaliddata needs SeManageVolumePrivilege — held by elevated admins.
	if out, err := runCmd("fsutil", "file", "setvaliddata", path,
		fmt.Sprintf("%d", sizeBytes)); err != nil {
		return fmt.Errorf("fsutil setvaliddata (VDL extension): %w: %s", err, strings.TrimSpace(out))
	}

	// Two distinct failures, reported separately. Folding them into one branch
	// dereferenced a nil st whenever Stat itself failed — so the path that runs
	// ONLY when disk creation has already gone wrong panicked instead of saying
	// what went wrong (#191).
	st, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("root.disk verification failed: cannot stat %s: %w", path, err)
	}
	if st.Size() != sizeBytes {
		return fmt.Errorf("root.disk verification failed: got %d bytes, want %d", st.Size(), sizeBytes)
	}
	return nil
}
