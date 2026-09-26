//go:build !windows

package main

import (
	"context"
	"fmt"
	"os"
	"runtime"
	"time"
)

// ── Dev stubs (non-Windows) ───────────────────────────────────────────────────
// These allow `wails dev` to run on Linux/macOS for UI development.
// None of these touch real Windows APIs.

func getSystemInfo() SystemInfo {
	return SystemInfo{
		OSVersion:      fmt.Sprintf("dev/%s (not Windows)", runtime.GOOS),
		FreeDiskGB:     240,
		TotalDiskGB:    512,
		BitLockerOn:    false,
		BitLockerState: "off",
		IsUEFI:         true,
		SecureBootOn:   false,
		// Dev builds are always "safe to start": these gates exist to describe
		// a real Windows machine, and a Linux/macOS dev box has no opinion.
		BatteryKnown: false,
		RAMGB:        16,
		Is64Bit:      true,
	}
}

func checkSystem() error                         { return nil }
func validatePlatformConfig(InstallConfig) error { return nil }
func defragDrive() error                         { return fmt.Errorf("defragmentation is only available on Windows") }
func disableFastStartup() error                  { return nil }
func recordKnownFolders()                        {}
func createDirectories() error                   { return os.MkdirAll("/tmp/wootc/install", 0o755) }
func createRootDisk(sizeGB int) error {
	// Create a small placeholder file for dev testing
	path := "/tmp/wootc/disks/root.vhdx"
	os.MkdirAll("/tmp/wootc/disks", 0o755)
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	f.Close()
	return nil
}

func downloadDeployer(ctx context.Context, progress func(float64)) error {
	// Simulate download progress for UI dev
	for i := 0; i <= 10; i++ {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
			progress(float64(i) / 10)
			time.Sleep(200 * time.Millisecond)
		}
	}
	return nil
}

func writeGrubConfig(cfg InstallConfig) error { return nil }
func setupESP(cfg InstallConfig) error        { return nil }
func configureBCD(cfg InstallConfig) error    { return nil }

func writeVault(cfg InstallConfig) error {
	vault := map[string]string{
		"username":    cfg.Username,
		"hostname":    cfg.Hostname,
		"image":       cfg.ImageRef,
		"distro_name": effectiveBranding().Name,
	}
	return marshalJSONToFile("/tmp/wootc/install/vault.json", vault)
}

// captureBitLockerRecoveryKey is Windows-only; the dev stub returns "".
func captureBitLockerRecoveryKey(vol string) string { return "" }

// writeBitLockerKey is Windows-only; the dev stub is a no-op.
func writeBitLockerKey(key string) error { return nil }

func collectLook() error                                          { return nil }
func collectWifi() error                                          { return nil }
func collectPrograms() error                                      { return nil }
func collectSessions() ([]SessionCandidate, error)                { return nil, nil }
func sessionCandidates() ([]SessionCandidate, error)              { return nil, nil }
func exportSession(string, string, bool) error                    { return nil }
func uninstall(ctx context.Context) error                         { return nil }
func uninstallWith(ctx context.Context, o UninstallOptions) error { return nil }
func getUninstallInfo() UninstallInfo                             { return UninstallInfo{Found: false} }
func rebootWindows() error                                        { return fmt.Errorf("reboot not available on %s", runtime.GOOS) }

// wootcDir returns the wootc data directory.
// On non-Windows this points to /tmp/wootc for dev/testing.
func wootcDir() string { return "/tmp/wootc" }

func setStorageDrive(string) {} // no-op in dev mode

// CreateDataPartition is Windows-only; the dev stub errors clearly.
func (a *App) CreateDataPartition(sizeGB int) (DataPartition, error) {
	return DataPartition{}, fmt.Errorf("creating a data partition is only available on Windows")
}

func restrictFileACL(path string) error { return nil } // no-op on Linux

// disarmOneShot is Windows-only (BCD one-shot removal); no-op elsewhere.
func disarmOneShot() {}

// Windows-only surfaces of the leave-cleanly story; no-ops elsewhere.
func armOneShotFromPersistedGUID() error {
	return fmt.Errorf("boot arming is only available on Windows")
}
func registerUninstallEntry() {}
