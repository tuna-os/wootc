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
	"slices"
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
	PreparedParentExited, PreparedJobDrained, PreparedStreamsDrained, PreparedForcedCleanup bool
	ExitCode                                                                                int
	Stdout, Stderr                                                                          []byte
	Phase, AuditStage, ContextState                                                         string
	CommandAttempted, CommandStarted, WaitCompleted                                         bool
	CommandPID                                                                              int
	DeadlineExceeded                                                                        bool
	AuditMilliseconds, CommandMilliseconds                                                  int64
	CallPhase                                                                               string
	CallMilliseconds                                                                        int64
	PhaseTimings                                                                            map[string]int64
}

func (e *nativeStorageObservationFailure) Error() string {
	return "storage observation command refused"
}

// Only fixed enums and bounded process/timing facts cross the authenticated
// current-response boundary. Captured command text/streams never leave here.
func (e *nativeStorageObservationFailure) nativeConfigurationDiagnostic() any {
	if !slices.Contains([]string{"no-child-phase-observed", "load-cim-assemblies", "import-utility", "import-cim", "import-storage", "import-bitlocker", "read-volumes", "read-partition", "read-disk", "read-protection", "serialize"}, e.Phase) || !slices.Contains([]string{"not-started", "kernel-directories", "storage-assembly", "cim-assemblies", "interpreter", "storage-module", "bitlocker-module", "utility-module", "cim-module", "complete"}, e.AuditStage) || !slices.Contains([]string{"active", "canceled", "deadline", "unavailable"}, e.ContextState) || e.CommandPID < 0 || e.AuditMilliseconds < 0 || e.CommandMilliseconds < 0 || e.AuditMilliseconds > 60000 || e.CommandMilliseconds > 60000 || e.AuditMilliseconds+e.CommandMilliseconds > 60000 || (e.CommandStarted && (!e.CommandAttempted || e.CommandPID == 0)) || (!e.CommandStarted && e.CommandPID != 0) || (e.WaitCompleted && !e.CommandStarted) || (!e.CommandAttempted && e.CommandMilliseconds != 0) || (!e.WaitCompleted && e.ExitCode != -1) || (e.DeadlineExceeded != (e.ContextState == "deadline")) || (!e.CommandStarted && e.Phase != "no-child-phase-observed") {
		return nil
	}
	phase, total, timings := e.CallPhase, e.CallMilliseconds, e.PhaseTimings
	if phase == "" {
		phase = "standalone-query"
		total = e.AuditMilliseconds + e.CommandMilliseconds
		timings = map[string]int64{}
		for _, name := range nativeConfigurationPhases {
			timings[name] = 0
		}
		timings["storage-first-query"] = total
	}
	if total < 0 || total > 60000 || len(timings) != len(nativeConfigurationPhases) {
		return nil
	}
	var sum int64
	for _, name := range nativeConfigurationPhases {
		duration, ok := timings[name]
		if !ok || duration < 0 || duration > 60000 {
			return nil
		}
		sum += duration
	}
	if sum > total || total-sum > 256 || (phase != "standalone-query" && !slices.Contains(nativeConfigurationPhases, phase)) {
		return nil
	}
	return map[string]any{"callPhase": phase, "callMilliseconds": total, "phaseTimings": timings, "schemaVersion": 1, "kind": "storage-observation", "phase": e.Phase, "auditStage": e.AuditStage, "contextState": e.ContextState, "commandAttempted": e.CommandAttempted, "commandStarted": e.CommandStarted, "waitCompleted": e.WaitCompleted, "commandPid": e.CommandPID, "exitCode": e.ExitCode, "deadlineExceeded": e.DeadlineExceeded, "auditMilliseconds": e.AuditMilliseconds, "commandMilliseconds": e.CommandMilliseconds}
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
	command, auditMilliseconds, err := prepareNativeStorageCommand(ctx)
	if err != nil {
		return nil, err
	}
	output := &boundedNativeOutput{}
	command.Stdout = output
	stderr := &boundedNativeOutput{}
	command.Stderr = stderr

	commandStarted := time.Now()
	failure := func() *nativeStorageObservationFailure {
		return &nativeStorageObservationFailure{ExitCode: storageQueryExitCode(command), Stdout: append([]byte(nil), output.Bytes()...), Stderr: append([]byte(nil), stderr.Bytes()...), Phase: nativeStoragePhase(stderr.Bytes()), AuditStage: "complete", ContextState: nativeStorageContextState(ctx), CommandAttempted: true, CommandStarted: command.Process != nil, WaitCompleted: command.ProcessState != nil, CommandPID: storageQueryPID(command), DeadlineExceeded: ctx.Err() == context.DeadlineExceeded, AuditMilliseconds: auditMilliseconds, CommandMilliseconds: time.Since(commandStarted).Milliseconds()}
	}
	// Only the fixed error class reaches the caller; no arbitrary stderr text.
	if err := command.Run(); err != nil {
		return nil, failure()
	}
	rows, err := decodeNativeStorageRows(output.Bytes())
	if err != nil {
		return nil, failure()
	}
	return rows, nil
}

func prepareNativeStorageCommand(ctx context.Context) (*exec.Cmd, int64, error) {
	started := time.Now()
	auditStage := "kernel-directories"
	auditFailure := func() error {
		return &nativeStorageObservationFailure{ExitCode: -1, Phase: "no-child-phase-observed", AuditStage: auditStage, ContextState: nativeStorageContextState(ctx), DeadlineExceeded: ctx.Err() == context.DeadlineExceeded, AuditMilliseconds: time.Since(started).Milliseconds()}
	}
	systemDirectory, err := windows.GetSystemDirectory()
	if err != nil {
		return nil, 0, auditFailure()
	}
	windowsDirectory, err := windows.GetWindowsDirectory()
	if err != nil {
		return nil, 0, auditFailure()
	}
	if !strings.EqualFold(filepath.Clean(systemDirectory), filepath.Join(windowsDirectory, "System32")) {
		return nil, 0, auditFailure()
	}
	// The protected Storage manifest resolves this assembly through windir.
	// Bind both environment spellings to the kernel-observed Windows directory.
	auditStage = "storage-assembly"
	if err := auditNativePackagePath(filepath.Join(systemDirectory, "Microsoft.Windows.Storage.Core.dll")); err != nil {
		return nil, 0, auditFailure()
	}
	shellDirectory := filepath.Join(systemDirectory, "WindowsPowerShell", "v1.0")
	shellPath := filepath.Join(shellDirectory, "powershell.exe")
	// The Windows PowerShell CIM manifest names strong-named GAC assemblies,
	// not DLLs in PSHOME. Audit the observed .NET 4 system binding before load.
	auditStage = "cim-assemblies"
	for _, name := range []string{"Microsoft.Management.Infrastructure", "Microsoft.Management.Infrastructure.CimCmdlets"} {
		assembly := filepath.Join(windowsDirectory, "Microsoft.NET", "assembly", "GAC_MSIL", name, "v4.0_1.0.0.0__31bf3856ad364e35", name+".dll")
		if err := auditNativePackagePath(assembly); err != nil {
			return nil, 0, auditFailure()
		}
	}
	// Apply the current protected-path policy, including all ancestors.
	// This observation does not repair ACLs or create state.
	auditStage = "interpreter"
	if err := auditNativePackagePath(shellPath); err != nil {
		return nil, 0, auditFailure()
	}
	for _, name := range []string{"Storage", "BitLocker", "Microsoft.PowerShell.Utility", "CimCmdlets"} {
		auditStage = map[string]string{"Storage": "storage-module", "BitLocker": "bitlocker-module", "Microsoft.PowerShell.Utility": "utility-module", "CimCmdlets": "cim-module"}[name]
		module := filepath.Join(shellDirectory, "Modules", name)
		if err := auditNativePackagePath(module); err != nil {
			return nil, 0, auditFailure()
		}
		if err := auditNativeStatusTree(ctx, module, 512, func(path string) error { return inspectStateObject(path, false) }); err != nil {
			return nil, 0, auditFailure()
		}
	}
	command := exec.CommandContext(ctx, shellPath, "-NoProfile", "-NonInteractive", "-Command", nativeStorageQuery)
	environment := make([]string, 0, len(os.Environ())+2)
	for _, variable := range os.Environ() {
		key, _, _ := strings.Cut(variable, "=")
		if !strings.EqualFold(key, "PSModulePath") && !strings.EqualFold(key, "PSModuleAnalysisCachePath") && !strings.EqualFold(key, "PATH") && !strings.EqualFold(key, "windir") && !strings.EqualFold(key, "SystemRoot") && !strings.EqualFold(key, "WOOTC_NATIVE_STORAGE_SESSION") {
			environment = append(environment, variable)
		}
	}
	command.Env = append(environment, "PSModulePath="+filepath.Join(shellDirectory, "Modules"), "PSModuleAnalysisCachePath=NUL", "PATH="+systemDirectory, "windir="+windowsDirectory, "SystemRoot="+windowsDirectory)
	command.Dir = shellDirectory
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	command.WaitDelay = time.Second
	return command, time.Since(started).Milliseconds(), nil
}

func decodeNativeStorageRows(data []byte) ([]nativeStorageRow, error) {
	var raw []json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil || raw == nil || len(raw) > 26 {
		return nil, fmt.Errorf("storage rows refused")
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
	return observeNativeStorageTimed(ctx, between, nil)
}
func observeNativeStorageTimed(ctx context.Context, between func() error, mark func(string)) (result []NativeConfigurationStorage, resultErr error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if mark != nil {
		mark("storage-first-query")
	}
	session, err := startNativeStorageSession(ctx)
	if err != nil {
		return nil, err
	}
	defer func() {
		if closeErr := session.close(true); closeErr != nil && resultErr == nil {
			result = nil
			resultErr = session.failure()
		}
	}()
	return observeNativeStorageWithTiming(ctx, between, session.query, observeNativeNtfsSerial, func(letter string) (uint64, uint64, error) {
		path, _ := windows.UTF16PtrFromString(letter + `:\`)
		var available, total uint64
		err := windows.GetDiskFreeSpaceEx(path, &available, &total, nil)
		return available, total, err
	}, mark)
}

func observeNativeStorageWith(ctx context.Context, between func() error, query func(context.Context) ([]nativeStorageRow, error), serialRead func(string) (string, error), capacityRead func(string) (uint64, uint64, error)) ([]NativeConfigurationStorage, error) {
	return observeNativeStorageWithTiming(ctx, between, query, serialRead, capacityRead, nil)
}
func observeNativeStorageWithTiming(ctx context.Context, between func() error, query func(context.Context) ([]nativeStorageRow, error), serialRead func(string) (string, error), capacityRead func(string) (uint64, uint64, error), mark func(string)) ([]NativeConfigurationStorage, error) {
	if mark != nil {
		mark("storage-first-query")
	}
	before, err := query(ctx)
	if err != nil {
		return nil, err
	}
	if mark != nil {
		mark("storage-capacity")
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
	if mark != nil {
		mark("metadata-read")
	}
	if err := between(); err != nil {
		return nil, err
	}
	if mark != nil {
		mark("storage-second-query")
	}
	after, err := query(ctx)
	if err != nil {
		return nil, err
	}
	if mark != nil {
		mark("storage-identity-reread")
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

// Phase names originate in the fixed script; never promote arbitrary child text.
func nativeStoragePhase(stderr []byte) string {
	phase := "no-child-phase-observed"
	allowed := map[string]bool{"load-cim-assemblies": true, "import-utility": true, "import-cim": true, "import-storage": true, "import-bitlocker": true, "read-volumes": true, "read-partition": true, "read-disk": true, "read-protection": true, "serialize": true}
	for _, line := range strings.Split(string(stderr), "\n") {
		value, ok := strings.CutPrefix(strings.TrimSuffix(line, "\r"), "storage-phase|")
		if ok && allowed[value] {
			phase = value
		}
	}
	return phase
}

func storageQueryPID(command *exec.Cmd) int {
	if command.Process == nil {
		return 0
	}
	return command.Process.Pid
}
func nativeStorageContextState(ctx context.Context) string {
	switch ctx.Err() {
	case nil:
		return "active"
	case context.Canceled:
		return "canceled"
	case context.DeadlineExceeded:
		return "deadline"
	default:
		return "unavailable"
	}
}
