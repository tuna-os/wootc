package main

// Tests for the non-Windows dev stubs (installer_other.go), which had zero
// coverage. These run in CI's Linux job: the stubs are the `wails dev`
// surface and the error paths they return are what UI devs actually see on
// a non-Windows machine.

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRebootWindows_NotOnLinux(t *testing.T) {
	err := rebootWindows()
	if err == nil {
		t.Fatal("rebootWindows on non-Windows: expected error")
	}
	if !strings.Contains(err.Error(), "reboot not available") {
		t.Errorf("error = %v, want 'reboot not available'", err)
	}
}

func TestGetUninstallInfo_NotInstalled(t *testing.T) {
	info := getUninstallInfo()
	if info.Found {
		t.Error("getUninstallInfo on non-Windows: Found should be false")
	}
}

func TestCreateDataPartition_Unavailable(t *testing.T) {
	a := &App{}
	_, err := a.CreateDataPartition(20)
	if err == nil {
		t.Fatal("CreateDataPartition on non-Windows: expected error")
	}
	if !strings.Contains(err.Error(), "only available on Windows") {
		t.Errorf("error = %v", err)
	}
}

func TestGetSystemInfo_DevShape(t *testing.T) {
	info := getSystemInfo()
	if !info.IsUEFI || !info.Is64Bit {
		t.Error("dev getSystemInfo: IsUEFI/Is64Bit should be true")
	}
	if info.BitLockerOn {
		t.Error("dev getSystemInfo: BitLockerOn should be false")
	}
	if info.OSVersion == "" {
		t.Error("dev getSystemInfo: OSVersion should be populated")
	}
}

func TestDefragDrive_Unavailable(t *testing.T) {
	err := defragDrive()
	if err == nil {
		t.Fatal("defragDrive on non-Windows: expected error")
	}
	if !strings.Contains(err.Error(), "only available on Windows") {
		t.Errorf("error = %v", err)
	}
}

func TestCheckSystem_AndValidatePlatformConfig_Noop(t *testing.T) {
	if err := checkSystem(); err != nil {
		t.Errorf("checkSystem: %v", err)
	}
	if err := validatePlatformConfig(InstallConfig{}); err != nil {
		t.Errorf("validatePlatformConfig: %v", err)
	}
	if err := disableFastStartup(); err != nil {
		t.Errorf("disableFastStartup: %v", err)
	}
}

func TestDownloadDeployer_ProgressAndCancel(t *testing.T) {
	var last float64 = -1
	calls := 0
	progress := func(p float64) { calls++; last = p }

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	err := downloadDeployer(ctx, progress)
	if err == nil {
		t.Fatal("downloadDeployer with cancelled ctx: expected context error")
	}
	if !errors.Is(err, context.Canceled) {
		t.Errorf("error = %v, want context.Canceled", err)
	}
	_ = last
}

func TestDownloadDeployer_Completes(t *testing.T) {
	progress := func(float64) {}
	if err := downloadDeployer(context.Background(), progress); err != nil {
		t.Fatalf("downloadDeployer: %v", err)
	}
}

func TestCreateRootDisk_CreatesFile(t *testing.T) {
	// The dev stub writes to /tmp/wootc/disks/root.vhdx — clean it first so
	// the assertion is about this call, not a leftover.
	_ = os.Remove("/tmp/wootc/disks/root.vhdx")
	if err := createRootDisk(40); err != nil {
		t.Fatalf("createRootDisk: %v", err)
	}
	if _, err := os.Stat("/tmp/wootc/disks/root.vhdx"); err != nil {
		t.Errorf("root.vhdx not created: %v", err)
	}
}

func TestCreateDirectories_AndWriteVault(t *testing.T) {
	if err := createDirectories(); err != nil {
		t.Fatalf("createDirectories: %v", err)
	}
	cfg := InstallConfig{Username: "u", Hostname: "h", ImageRef: "ghcr.io/tuna-os/foo"}
	if err := writeVault(cfg); err != nil {
		t.Fatalf("writeVault: %v", err)
	}
	data, err := os.ReadFile(filepath.Join("/tmp/wootc", "install", "vault.json"))
	if err != nil {
		t.Fatalf("vault.json not written: %v", err)
	}
	if !strings.Contains(string(data), "ghcr.io/tuna-os/foo") {
		t.Errorf("vault missing image ref: %s", data)
	}
}

func TestUninstallStubs_NoopOnNonWindows(t *testing.T) {
	if err := uninstall(context.Background()); err != nil {
		t.Errorf("uninstall: %v", err)
	}
	if err := uninstallWith(context.Background(), UninstallOptions{}); err != nil {
		t.Errorf("uninstallWith: %v", err)
	}
}

func TestCollectStubs_NoopOnNonWindows(t *testing.T) {
	if err := collectLook(); err != nil {
		t.Errorf("collectLook: %v", err)
	}
	if err := collectWifi(); err != nil {
		t.Errorf("collectWifi: %v", err)
	}
	if err := collectPrograms(); err != nil {
		t.Errorf("collectPrograms: %v", err)
	}
	cts, err := collectSessions()
	if err != nil || cts != nil {
		t.Errorf("collectSessions: %v %v", cts, err)
	}
	if err := exportSession("a", "b", false); err != nil {
		t.Errorf("exportSession: %v", err)
	}
	if err := restrictFileACL("/tmp/x"); err != nil {
		t.Errorf("restrictFileACL: %v", err)
	}
	setStorageDrive("/dev/sda")
}

func TestGrubConfigStubs_Noop(t *testing.T) {
	cfg := InstallConfig{Bootloader: "grub2"}
	if err := writeGrubConfig(cfg); err != nil {
		t.Errorf("writeGrubConfig: %v", err)
	}
	if err := setupESP(cfg); err != nil {
		t.Errorf("setupESP: %v", err)
	}
	if err := configureBCD(cfg); err != nil {
		t.Errorf("configureBCD: %v", err)
	}
	if key := captureBitLockerRecoveryKey("C:"); key != "" {
		t.Errorf("captureBitLockerRecoveryKey = %q, want empty", key)
	}
	if err := writeBitLockerKey("key"); err != nil {
		t.Errorf("writeBitLockerKey: %v", err)
	}
}
