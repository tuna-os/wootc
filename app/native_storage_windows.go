//go:build windows

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"golang.org/x/sys/windows"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

//go:embed native_storage_query.ps1
var nativeStorageQuery string

type nativeStorageRow struct {
	DriveLetter          string `json:"driveLetter"`
	DiskGUID             string `json:"diskGuid"`
	PartitionGUID        string `json:"partitionGuid"`
	VolumeStatus         string `json:"volumeStatus"`
	ProtectionStatus     string `json:"protectionStatus"`
	EncryptionPercentage int    `json:"encryptionPercentage"`
}

type boundedNativeOutput struct{ bytes.Buffer }

func (b *boundedNativeOutput) Write(p []byte) (int, error) {
	if b.Len()+len(p) > 64*1024 {
		return 0, fmt.Errorf("storage observation exceeds bound")
	}
	return b.Buffer.Write(p)
}

type nativeStorageObservationFailure struct {
	ExitCode       int
	Stdout, Stderr []byte
}

func (e *nativeStorageObservationFailure) Error() string {
	return "storage observation command refused"
}

func storageQueryExitCode(command *exec.Cmd) int {
	if command.ProcessState == nil {
		return -1
	}
	return command.ProcessState.ExitCode()
}

func queryNativeStorage(ctx context.Context) ([]nativeStorageRow, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	systemDirectory, err := windows.GetSystemDirectory()
	if err != nil {
		return nil, err
	}
	shellDirectory := filepath.Join(systemDirectory, "WindowsPowerShell", "v1.0")
	shellPath := filepath.Join(shellDirectory, "powershell.exe")
	// Apply the existing protected-path policy, including all ancestors;
	// this is observation only and borrows no relaxed drive-root exception.
	if err := auditNativePackagePath(shellPath); err != nil {
		return nil, err
	}
	for _, name := range []string{"Storage", "BitLocker", "Microsoft.PowerShell.Utility"} {
		module := filepath.Join(shellDirectory, "Modules", name)
		if err := auditNativePackagePath(module); err != nil {
			return nil, err
		}
		if err := auditNativeStatusTree(ctx, module, 512, func(path string) error { return inspectStateObject(path, false) }); err != nil {
			return nil, err
		}
	}
	command := exec.CommandContext(ctx, shellPath, "-NoProfile", "-NonInteractive", "-Command", nativeStorageQuery)
	environment := make([]string, 0, len(os.Environ())+2)
	for _, variable := range os.Environ() {
		key, _, _ := strings.Cut(variable, "=")
		if !strings.EqualFold(key, "PSModulePath") && !strings.EqualFold(key, "PSModuleAnalysisCachePath") && !strings.EqualFold(key, "PATH") {
			environment = append(environment, variable)
		}
	}
	command.Env = append(environment, "PSModulePath="+filepath.Join(shellDirectory, "Modules"), "PSModuleAnalysisCachePath=NUL", "PATH="+systemDirectory)
	command.Dir = shellDirectory
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	command.WaitDelay = time.Second
	output := &boundedNativeOutput{}
	command.Stdout = output
	stderr := &boundedNativeOutput{}
	command.Stderr = stderr
	// Only the fixed error class reaches the caller; no arbitrary stderr text.
	if err := command.Run(); err != nil {
		return nil, &nativeStorageObservationFailure{ExitCode: storageQueryExitCode(command), Stdout: append([]byte(nil), output.Bytes()...), Stderr: append([]byte(nil), stderr.Bytes()...)}
	}
	var raw []json.RawMessage
	if err := json.Unmarshal(output.Bytes(), &raw); err != nil || raw == nil || len(raw) > 26 {
		return nil, fmt.Errorf("storage observation shape refused")
	}
	rows := make([]nativeStorageRow, 0, len(raw))
	seen := map[string]bool{}
	for _, data := range raw {
		var row nativeStorageRow
		if err := decodeNativeMetadataObject(data, &row, []string{"driveLetter", "diskGuid", "partitionGuid", "volumeStatus", "protectionStatus", "encryptionPercentage"}); err != nil {
			return nil, err
		}
		if len(row.DriveLetter) != 1 || row.DriveLetter[0] < 'A' || row.DriveLetter[0] > 'Z' || seen[row.DriveLetter] {
			return nil, fmt.Errorf("storage drive identity refused")
		}
		seen[row.DriveLetter] = true
		disk, err := windows.GUIDFromString(row.DiskGUID)
		if err != nil || disk == (windows.GUID{}) {
			return nil, fmt.Errorf("storage disk identity refused")
		}
		partition, err := windows.GUIDFromString(row.PartitionGUID)
		if err != nil || partition == (windows.GUID{}) {
			return nil, fmt.Errorf("storage partition identity refused")
		}
		row.DiskGUID = strings.ToLower(disk.String())
		row.PartitionGUID = strings.ToLower(partition.String())
		if row.EncryptionPercentage < 0 || row.EncryptionPercentage > 100 || (row.ProtectionStatus != "Off" && row.ProtectionStatus != "On") {
			return nil, fmt.Errorf("storage protection observation refused")
		}
		switch row.VolumeStatus {
		case "FullyDecrypted", "FullyEncrypted", "EncryptionInProgress", "DecryptionInProgress", "EncryptionPaused", "DecryptionPaused":
		default:
			return nil, fmt.Errorf("storage conversion observation refused")
		}
		rows = append(rows, row)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].DriveLetter < rows[j].DriveLetter })
	return rows, nil
}

// Microsoft NTFS_VOLUME_DATA_BUFFER starts with the full 64-bit serial. The
// complete 96-byte basic buffer is required; GetVolumeInformation truncates it.
func observeNativeNtfsSerial(letter string) (string, error) {
	if len(letter) != 1 || letter[0] < 'A' || letter[0] > 'Z' {
		return "", fmt.Errorf("invalid NTFS drive")
	}
	path, err := windows.UTF16PtrFromString(`\\.\` + letter + `:`)
	if err != nil {
		return "", err
	}
	handle, err := windows.CreateFile(path, windows.GENERIC_READ, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		return "", err
	}
	defer windows.CloseHandle(handle)
	var data [96]byte
	var returned uint32
	if err := windows.DeviceIoControl(handle, 0x00090064, nil, 0, &data[0], uint32(len(data)), &returned, nil); err != nil {
		return "", err
	}
	if returned < uint32(len(data)) || binary.LittleEndian.Uint64(data[:8]) == 0 {
		return "", fmt.Errorf("NTFS identity incomplete")
	}
	return fmt.Sprintf("%016x", binary.LittleEndian.Uint64(data[:8])), nil
}

func observeNativeStorage(ctx context.Context, between func() error) ([]NativeConfigurationStorage, error) {
	return observeNativeStorageWith(ctx, between, queryNativeStorage, observeNativeNtfsSerial, func(letter string) (uint64, uint64, error) {
		path, _ := windows.UTF16PtrFromString(letter + `:\`)
		var available, total uint64
		err := windows.GetDiskFreeSpaceEx(path, &available, &total, nil)
		return available, total, err
	})
}

func observeNativeStorageWith(ctx context.Context, between func() error, query func(context.Context) ([]nativeStorageRow, error), serialRead func(string) (string, error), capacityRead func(string) (uint64, uint64, error)) ([]NativeConfigurationStorage, error) {
	before, err := query(ctx)
	if err != nil {
		return nil, err
	}
	results := make([]NativeConfigurationStorage, 0, len(before))
	for _, row := range before {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		// Encrypted, paused and in-progress volumes are never offered as an
		// unencrypted host for root.disk. This observation grants no operation.
		if row.VolumeStatus != "FullyDecrypted" || row.ProtectionStatus != "Off" || row.EncryptionPercentage != 0 {
			continue
		}
		serial, err := serialRead(row.DriveLetter)
		if err != nil {
			return nil, err
		}
		available, total, err := capacityRead(row.DriveLetter)
		if err != nil {
			return nil, err
		}
		if available > total || total > uint64(^uint64(0)>>1) {
			return nil, fmt.Errorf("storage capacity refused")
		}
		size := available / (1 << 30)
		if size < 20 {
			continue
		}
		if size > 2048 {
			size = 2048
		}
		binding := sha256.Sum256([]byte(row.DiskGUID + "\n" + row.PartitionGUID + "\n" + serial))
		results = append(results, NativeConfigurationStorage{ID: hex.EncodeToString(binding[:]), DriveLetter: row.DriveLetter, DiskGUID: row.DiskGUID, PartitionGUID: row.PartitionGUID, NtfsSerial: serial, FreeBytes: int64(available), MaximumRootDiskSizeGB: int(size)})
	}
	if err := between(); err != nil {
		return nil, err
	}
	after, err := query(ctx)
	if err != nil {
		return nil, err
	}
	if len(before) != len(after) {
		return nil, fmt.Errorf("storage set changed")
	}
	for i := range before {
		if before[i] != after[i] {
			return nil, fmt.Errorf("storage identity or protection changed")
		}
	}
	for _, result := range results {
		serial, err := serialRead(result.DriveLetter)
		if err != nil || serial != result.NtfsSerial {
			return nil, fmt.Errorf("NTFS identity changed")
		}
	}
	return results, nil
}
