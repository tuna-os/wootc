package main

// Tests for the cross-platform bridge's E2E drive protocol and install
// status/cancellation behavior. File-backed channels use owned fixtures.

import (
	"os"
	"path/filepath"
	"testing"
)

func newE2EFixture(t *testing.T) *App {
	t.Helper()
	root := t.TempDir()
	return &App{drivePath: func(name string) string { return filepath.Join(root, name) }}
}

func removeE2EFiles(t *testing.T, app *App) {
	t.Helper()
	for _, name := range []string{"e2e-drive.json", "e2e-drive-state.json", "e2e-ready.json"} {
		if err := os.Remove(app.e2ePath(name)); err != nil && !os.IsNotExist(err) {
			t.Fatal(err)
		}
	}
}

// ── E2E drive mode ───────────────────────────────────────────────────────────

func TestE2EDriveDirectiveDisabledByDefault(t *testing.T) {
	app := newE2EFixture(t)
	t.Setenv("WOOTC_E2E_DRIVE", "")
	if got := app.E2EDriveDirective(); got != "" {
		t.Errorf("E2EDriveDirective without WOOTC_E2E_DRIVE = %q, want \"\"", got)
	}
}

func TestE2EDriveDirectiveReadsDirectiveFile(t *testing.T) {
	t.Setenv("WOOTC_E2E_DRIVE", "1")
	app := newE2EFixture(t)
	payload := `{"click": "continue"}`
	if err := os.WriteFile(app.e2ePath("e2e-drive.json"), []byte(payload), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := app.E2EDriveDirective(); got != payload {
		t.Errorf("E2EDriveDirective = %q, want %q", got, payload)
	}
}

func TestE2EDriveDirectiveMissingFile(t *testing.T) {
	t.Setenv("WOOTC_E2E_DRIVE", "1")
	app := newE2EFixture(t)
	if got := app.E2EDriveDirective(); got != "" {
		t.Errorf("E2EDriveDirective with no file = %q, want \"\"", got)
	}
}

func TestE2EDriveReportWritesStateWhenEnabled(t *testing.T) {
	t.Setenv("WOOTC_E2E_DRIVE", "1")
	app := newE2EFixture(t)
	directive := `{"schemaVersion":1,"runId":"current","directiveId":"1234567890abcdef1234567890abcdef","action":"install"}`
	report := `{"schemaVersion":1,"runId":"current","directiveId":"1234567890abcdef1234567890abcdef","action":"install","screen":"progress","installDriven":true,"installBtnDisabled":null,"hint":"","progressStep":"","error":null,"selectedRef":"image","imageMismatch":false}`
	if err := os.WriteFile(app.e2ePath("e2e-drive.json"), []byte(directive), 0o600); err != nil {
		t.Fatal(err)
	}
	app.E2EDriveReport(report)
	data, err := os.ReadFile(app.e2ePath("e2e-drive-state.json"))
	if err != nil {
		t.Fatalf("E2EDriveReport did not write state: %v", err)
	}
	if string(data) != report {
		t.Errorf("state file = %q, want bound report", data)
	}
}

func TestE2EDriveReportNoopWhenDisabled(t *testing.T) {
	t.Setenv("WOOTC_E2E_DRIVE", "")
	app := newE2EFixture(t)
	app.E2EDriveReport("installing")
	if _, err := os.Stat(app.e2ePath("e2e-drive-state.json")); !os.IsNotExist(err) {
		t.Error("E2EDriveReport wrote state while drive mode was off")
	}
}

func TestE2EDriveReadyWritesMarkerWithoutDirective(t *testing.T) {
	// The deadlock this fixes: readiness waited for a bound drive report,
	// which needs the install directive, which is only written after launch
	// is confirmed. The marker must appear with NO directive file present.
	t.Setenv("WOOTC_E2E_DRIVE", "1")
	app := newE2EFixture(t)
	ready := `{"schemaVersion":1,"screen":"launchpad"}`
	app.E2EDriveReady(ready)
	data, err := os.ReadFile(app.e2ePath("e2e-ready.json"))
	if err != nil {
		t.Fatalf("E2EDriveReady did not write marker: %v", err)
	}
	if string(data) != ready {
		t.Errorf("ready file = %q, want %q", data, ready)
	}
	if _, err := os.Stat(app.e2ePath("e2e-drive-state.json")); !os.IsNotExist(err) {
		t.Error("E2EDriveReady must not write the bound drive-state channel")
	}
}

func TestE2EDriveReadyNoopWhenDisabled(t *testing.T) {
	t.Setenv("WOOTC_E2E_DRIVE", "")
	app := newE2EFixture(t)
	app.E2EDriveReady(`{"schemaVersion":1,"screen":"launchpad"}`)
	if _, err := os.Stat(app.e2ePath("e2e-ready.json")); !os.IsNotExist(err) {
		t.Error("E2EDriveReady wrote marker while drive mode was off")
	}
}

func TestE2EDriveReadyRejectsMalformed(t *testing.T) {
	t.Setenv("WOOTC_E2E_DRIVE", "1")
	for _, bad := range []string{
		"",
		"not json",
		`{"schemaVersion":1}`,
		`{"screen":"launchpad"}`,
		`{"schemaVersion":2,"screen":"launchpad"}`,
		`{"schemaVersion":1,"screen":""}`,
		`{"schemaVersion":1,"screen":42}`,
		`{"schemaVersion":1,"screen":"launchpad","extra":true}`,
		`{"schemaVersion":1,"screen":"launchpad"}{"schemaVersion":1,"screen":"launchpad"}`,
	} {
		app := newE2EFixture(t)
		app.E2EDriveReady(bad)
		if _, err := os.Stat(app.e2ePath("e2e-ready.json")); !os.IsNotExist(err) {
			t.Errorf("E2EDriveReady wrote marker for %q", bad)
		}
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
