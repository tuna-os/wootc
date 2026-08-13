package main

// Tests for the headless CLI contract (headless.go) and the lifecycle state
// bus (state.go). These are the exact paths E2E and unattended installs
// depend on (wootc install/status over QGA), and previously had 0% coverage.
//
// None of these tests trigger the real install pipeline: every headlessInstall
// case exits in flag parsing / argument validation before runPipeline is
// reached, and the state tests operate on the dev-mode wootcDir (/tmp/wootc).

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ── isHeadlessInvocation ─────────────────────────────────────────────────────

func TestIsHeadlessInvocation(t *testing.T) {
	cases := []struct {
		args []string
		want bool
	}{
		{args: nil, want: false},
		{[]string{"wootc"}, false},
		{[]string{"wootc", "install"}, true},
		{[]string{"wootc", "status"}, true},
		{[]string{"wootc", "uninstall"}, true},
		{[]string{"wootc", "install", "--image", "ghcr.io/tuna-os/foo", "--username", "u"}, true},
		{[]string{"wootc", "gui"}, false},
		{[]string{"wootc", "INSTALL"}, false},
	}
	for _, c := range cases {
		if got := isHeadlessInvocation(c.args); got != c.want {
			t.Errorf("isHeadlessInvocation(%v) = %v, want %v", c.args, got, c.want)
		}
	}
}

// ── runHeadless dispatch ─────────────────────────────────────────────────────

func TestRunHeadlessUnknownSubcommandExits2(t *testing.T) {
	if got := runHeadless([]string{"wootc", "frobnicate"}); got != 2 {
		t.Errorf("runHeadless(unknown) = %d, want 2", got)
	}
}

// ── headlessInstall argument validation (never reaches runPipeline) ─────────

func TestHeadlessInstallRequiresAllCredentials(t *testing.T) {
	cases := [][]string{
		{"-image", "ghcr.io/tuna-os/foo"},                   // no username/password
		{"-image", "ghcr.io/tuna-os/foo", "-username", "u"}, // no password
		{"-username", "u", "-password", "p"},                // no image
	}
	for _, args := range cases {
		if got := headlessInstall(args); got != 2 {
			t.Errorf("headlessInstall(%v) = %d, want 2 (validation failure)", args, got)
		}
	}
}

func TestHeadlessInstallRejectsUnknownFlag(t *testing.T) {
	if got := headlessInstall([]string{"--definitely-not-a-flag"}); got != 2 {
		t.Errorf("headlessInstall(bad flag) = %d, want 2", got)
	}
}

func TestHeadlessInstallRejectsBadBootloader(t *testing.T) {
	// All required flags present, but a typo'd -bootloader must fail in
	// validation rather than falling through to the auto path.
	args := []string{
		"-image", "ghcr.io/tuna-os/foo",
		"-username", "u",
		"-password", "p",
		"-bootloader", "grub99",
	}
	if got := headlessInstall(args); got != 2 {
		t.Errorf("headlessInstall(bad bootloader) = %d, want 2", got)
	}
}

// ── headlessStatus ───────────────────────────────────────────────────────────

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	defer func() { os.Stdout = old }()
	fn()
	_ = w.Close()
	data, _ := io.ReadAll(r)
	return string(data)
}

func TestHeadlessStatusAbsentState(t *testing.T) {
	_ = os.Remove(statePath())
	out := captureStdout(t, func() {
		if code := headlessStatus(); code != 0 {
			t.Errorf("headlessStatus(absent) = %d, want 0", code)
		}
	})
	if !strings.Contains(out, `{"state":"absent"}`) {
		t.Errorf("headlessStatus(absent) output = %q, want state absent JSON", out)
	}
}

func TestHeadlessStatusPrintsStateJSON(t *testing.T) {
	dir := filepath.Dir(statePath())
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	defer os.Remove(statePath())
	writeState(StateDeployed, "deploy", "")

	out := captureStdout(t, func() {
		if code := headlessStatus(); code != 0 {
			t.Errorf("headlessStatus(present) = %d, want 0", code)
		}
	})
	if !strings.Contains(out, `"state": "deployed"`) || !strings.Contains(out, `"phase": "deploy"`) {
		t.Errorf("headlessStatus(present) output = %q, want deployed state JSON", out)
	}
}

// ── lifecycle state bus ──────────────────────────────────────────────────────

func TestStateRoundTrip(t *testing.T) {
	dir := filepath.Dir(statePath())
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	defer os.Remove(statePath())

	writeState(StateArmed, "phase1", "")
	s, ok := readState()
	if !ok {
		t.Fatal("readState returned ok=false after writeState")
	}
	if s.State != StateArmed {
		t.Errorf("state.State = %q, want %q", s.State, StateArmed)
	}
	if s.Phase != "phase1" {
		t.Errorf("state.Phase = %q, want phase1", s.Phase)
	}
	if s.UpdatedBy != "wootc-installer" {
		t.Errorf("state.UpdatedBy = %q, want wootc-installer", s.UpdatedBy)
	}
	if s.UpdatedAt == "" {
		t.Error("state.UpdatedAt must be set")
	}
}

func TestStateRoundTripFailureFields(t *testing.T) {
	dir := filepath.Dir(statePath())
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	defer os.Remove(statePath())

	writeState(StateFailed, "install", "disk write failed")
	s, ok := readState()
	if !ok || s.State != StateFailed {
		t.Fatalf("readState = (%+v, %v), want failed state", s, ok)
	}
	if s.Error != "disk write failed" {
		t.Errorf("state.Error = %q, want disk write failed", s.Error)
	}
}

func TestReadStateMissingFile(t *testing.T) {
	_ = os.Remove(statePath())
	if _, ok := readState(); ok {
		t.Error("readState on missing file returned ok=true")
	}
}

func TestReadStateCorruptJSON(t *testing.T) {
	dir := filepath.Dir(statePath())
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statePath(), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	defer os.Remove(statePath())
	if _, ok := readState(); ok {
		t.Error("readState on corrupt JSON returned ok=true")
	}
}

// ── mode detection ───────────────────────────────────────────────────────────

func TestDetectModeInstallerWhenHostNotBridged(t *testing.T) {
	// On a CI/dev box /run/wootc/host is never mounted, so the mode must be
	// the installer surface. If this flakes, the runner actually has a wootc
	// host bridge mounted — which would be surprising.
	if got := detectMode(); got != "installer" {
		t.Errorf("detectMode() = %q, want installer", got)
	}
}
