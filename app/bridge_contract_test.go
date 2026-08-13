package main

// Tests for the Wails Go<->JS bridge contract on the Linux dev build
// (app.go + installer_other.go dev stubs): E2E drive mode, install
// status/cancel, and the Windows-only operations that must fail clearly
// outside Windows. These pin the contract the GUI E2E drives and the
// dev-mode behavior developers rely on.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func removeE2EFiles(t *testing.T) {
	t.Helper()
	_ = os.Remove(e2eDrivePath("e2e-drive.json"))
	_ = os.Remove(e2eDrivePath("e2e-drive-state.json"))
}

// ── E2E drive mode ───────────────────────────────────────────────────────────

func TestE2EDrivePathDevLayout(t *testing.T) {
	if filepath.Separator == '\\' {
		t.Skip("Linux layout asserted; windows layout is C:\\wootc\\")
	}
	if got := e2eDrivePath("e2e-drive.json"); got != "/tmp/wootc-e2e-drive.json" {
		t.Errorf("e2eDrivePath = %q, want /tmp/wootc-e2e-drive.json", got)
	}
}

func TestE2EDriveDirectiveDisabledByDefault(t *testing.T) {
	t.Setenv("WOOTC_E2E_DRIVE", "")
	if got := (&App{}).E2EDriveDirective(); got != "" {
		t.Errorf("E2EDriveDirective without WOOTC_E2E_DRIVE = %q, want \"\"", got)
	}
}

func TestE2EDriveDirectiveReadsDirectiveFile(t *testing.T) {
	t.Setenv("WOOTC_E2E_DRIVE", "1")
	removeE2EFiles(t)
	defer removeE2EFiles(t)
	payload := `{"click": "continue"}`
	if err := os.WriteFile(e2eDrivePath("e2e-drive.json"), []byte(payload), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := (&App{}).E2EDriveDirective(); got != payload {
		t.Errorf("E2EDriveDirective = %q, want %q", got, payload)
	}
}

func TestE2EDriveDirectiveMissingFile(t *testing.T) {
	t.Setenv("WOOTC_E2E_DRIVE", "1")
	removeE2EFiles(t)
	defer removeE2EFiles(t)
	if got := (&App{}).E2EDriveDirective(); got != "" {
		t.Errorf("E2EDriveDirective with no file = %q, want \"\"", got)
	}
}

func TestE2EDriveReportWritesStateWhenEnabled(t *testing.T) {
	t.Setenv("WOOTC_E2E_DRIVE", "1")
	removeE2EFiles(t)
	defer removeE2EFiles(t)
	(&App{}).E2EDriveReport("installing")
	data, err := os.ReadFile(e2eDrivePath("e2e-drive-state.json"))
	if err != nil {
		t.Fatalf("E2EDriveReport did not write state: %v", err)
	}
	if string(data) != "installing" {
		t.Errorf("state file = %q, want installing", data)
	}
}

func TestE2EDriveReportNoopWhenDisabled(t *testing.T) {
	t.Setenv("WOOTC_E2E_DRIVE", "")
	removeE2EFiles(t)
	defer removeE2EFiles(t)
	(&App{}).E2EDriveReport("installing")
	if _, err := os.Stat(e2eDrivePath("e2e-drive-state.json")); !os.IsNotExist(err) {
		t.Error("E2EDriveReport wrote state while drive mode was off")
	}
}

// ── install status / cancel ──────────────────────────────────────────────────

func TestGetStatusZeroValue(t *testing.T) {
	s := (&App{}).GetStatus()
	if s.Running || s.Done || s.Existing || s.Error != "" {
		t.Errorf("fresh App GetStatus = %+v, want zero InstallStatus", s)
	}
}

func TestCancelInstallNoopWhenIdle(t *testing.T) {
	// No install running: cancel must be a safe no-op (nil cancel func).
	(&App{}).CancelInstall() // must not panic
}

func TestExistingInstallFoundFalseOnDev(t *testing.T) {
	if (&App{}).ExistingInstallFound() {
		t.Error("ExistingInstallFound = true on Linux dev build")
	}
}

// ── Windows-only operations on the dev build ─────────────────────────────────

func TestUninstallNoopOnDev(t *testing.T) {
	if err := (&App{}).Uninstall(); err != nil {
		t.Errorf("Uninstall on dev build = %v, want nil", err)
	}
}

func TestUninstallWithNoopOnDev(t *testing.T) {
	if err := (&App{}).UninstallWith(UninstallOptions{DeleteRootDisk: true}); err != nil {
		t.Errorf("UninstallWith on dev build = %v, want nil", err)
	}
}

func TestRebootUnavailableOnDev(t *testing.T) {
	err := (&App{}).Reboot()
	if err == nil {
		t.Fatal("Reboot on dev build succeeded, want error")
	}
	if !strings.Contains(err.Error(), "reboot not available") {
		t.Errorf("Reboot error = %v, want 'reboot not available'", err)
	}
}

func TestCreateDataPartitionWindowsOnly(t *testing.T) {
	_, err := (&App{}).CreateDataPartition(40)
	if err == nil {
		t.Fatal("CreateDataPartition on dev build succeeded, want error")
	}
	if !strings.Contains(err.Error(), "only available on Windows") {
		t.Errorf("CreateDataPartition error = %v, want Windows-only message", err)
	}
}
