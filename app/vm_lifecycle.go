package main

import (
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

const (
	vmPreparing = "preparing"
	vmReady     = "ready"
	vmStarting  = "starting"
	vmRunning   = "running"
	vmStopping  = "stopping"
	vmStopped   = "stopped"
	vmRecovery  = "needs_recovery"
	vmFailed    = "failed"
)

// VMState records the persistent installed system, not just a process. Ready
// means provisioning verified the disk; DesktopReady needs separate guest proof.
type VMState struct {
	SchemaVersion int    `json:"schemaVersion"`
	InstallID     string `json:"installId"`
	RunID         string `json:"runId"`
	Image         string `json:"image"`
	DiskID        string `json:"diskId"`
	DiskPath      string `json:"diskPath"`
	Phase         string `json:"phase"`
	DesktopReady  bool   `json:"desktopReady"`
	PID           int    `json:"pid"`
	Error         string `json:"error,omitempty"`
	UpdatedAt     string `json:"updatedAt"`
}

func readVMState(path string) (VMState, error) {
	var state VMState
	f, err := os.Open(path)
	if err != nil {
		return state, err
	}
	defer f.Close()
	if err = json.NewDecoder(io.LimitReader(f, 64*1024)).Decode(&state); err != nil {
		return state, fmt.Errorf("read VM lifecycle: %w", err)
	}
	if state.SchemaVersion != 1 || state.InstallID == "" || state.DiskPath == "" {
		return state, fmt.Errorf("invalid VM lifecycle identity")
	}
	return state, nil
}

func writeVMState(path string, state VMState) error {
	state.SchemaVersion = 1
	state.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	// Never turn process or QMP liveness into a claim about a usable desktop.
	state.DesktopReady = false
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".vm-state-")
	if err != nil {
		return err
	}
	name := temp.Name()
	defer os.Remove(name)
	if _, err = temp.Write(data); err != nil {
		temp.Close()
		return err
	}
	if err = temp.Sync(); err != nil {
		temp.Close()
		return err
	}
	if err = temp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}

// The GPT disk GUID ties a helper's result and later VM launches to the same
// image. A preallocated file, process PID, or matching file size is insufficient.
func vmDiskIdentity(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	header := make([]byte, 92)
	if _, err = file.ReadAt(header, 512); err != nil {
		return "", err
	}
	if string(header[:8]) != "EFI PART" {
		return "", fmt.Errorf("VM disk has no GPT header")
	}
	guid := header[56:72]
	if hex.EncodeToString(guid) == "00000000000000000000000000000000" {
		return "", fmt.Errorf("VM disk has no identity")
	}
	return fmt.Sprintf("%08x-%04x-%04x-%x-%x", binary.LittleEndian.Uint32(guid), binary.LittleEndian.Uint16(guid[4:]), binary.LittleEndian.Uint16(guid[6:]), guid[8:10], guid[10:]), nil
}

func vmLaunchAllowed(state VMState, diskPath string) error {
	if state.Phase != vmReady && state.Phase != vmStopped {
		return fmt.Errorf("VM cannot start from %s; preserve its disk and resolve recovery first", state.Phase)
	}
	if filepath.Clean(state.DiskPath) != filepath.Clean(diskPath) {
		return fmt.Errorf("VM disk path differs from its recorded installation")
	}
	actual, err := vmDiskIdentity(diskPath)
	if err != nil {
		return err
	}
	if actual != state.DiskID {
		return fmt.Errorf("VM disk identity changed; refusing to boot another disk")
	}
	return nil
}
