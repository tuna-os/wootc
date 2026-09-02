package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEvaluateRecoveryDecisionTable(t *testing.T) {
	armed := ArmedState{
		BcdGuid:          "{12345678-1234-1234-1234-123456789abc}",
		EspPartitionGuid: "{esp-guid-1234}",
		EspFiles:         []string{"EFI/fedora/shimx64.efi", "EFI/wootc/deployer-vmlinuz"},
		StorageDrive:     "C",
		ImageRef:         "ghcr.io/tuna-os/yellowfin:gnome",
		Bootloader:       "grub2",
		Timestamp:        "2026-09-02T12:00:00Z",
		ExeHash:          "abcdef123456",
	}

	tempDir := t.TempDir()
	logDir := filepath.Join(tempDir, "logs")
	_ = os.MkdirAll(logDir, 0o755)
	logFile := filepath.Join(logDir, "deployer-last-journal.log")
	_ = os.WriteFile(logFile, []byte("line 1\nline 2\nline 3\nline 4\nerror: something failed\n"), 0o644)

	// Row 1: armed.json present, deployer-started absent, state=armed
	v1 := EvaluateRecovery(armed, false, LifecycleState{State: StateArmed}, tempDir)
	if v1.Verdict != VerdictNeverBooted {
		t.Errorf("Row 1: got verdict %q, want %q", v1.Verdict, VerdictNeverBooted)
	}
	if !v1.Untouched {
		t.Errorf("Row 1: expected Untouched to be true")
	}
	if !v1.CanTryAgain || !v1.CanRemove || !v1.CanRepair {
		t.Errorf("Row 1: expected all 3 actions enabled")
	}

	// Row 2: armed.json present, deployer-started present, state=deploying (interrupted)
	v2 := EvaluateRecovery(armed, true, LifecycleState{State: StateDeploying}, tempDir)
	if v2.Verdict != VerdictInterrupted {
		t.Errorf("Row 2: got verdict %q, want %q", v2.Verdict, VerdictInterrupted)
	}
	if !v2.Untouched {
		t.Errorf("Row 2: expected Untouched to be true")
	}
	if !v2.CanTryAgain || !v2.CanRemove || !v2.CanRepair {
		t.Errorf("Row 2: expected all 3 actions enabled")
	}

	// Row 3: armed.json present, deployer-started present, state=failed
	v3 := EvaluateRecovery(armed, true, LifecycleState{State: StateFailed, Phase: "fisherman", Error: "disk write error"}, tempDir)
	if v3.Verdict != VerdictFailed {
		t.Errorf("Row 3: got verdict %q, want %q", v3.Verdict, VerdictFailed)
	}
	if v3.Phase != "fisherman" {
		t.Errorf("Row 3: got phase %q, want 'fisherman'", v3.Phase)
	}
	if len(v3.LogTail) == 0 {
		t.Errorf("Row 3: expected non-empty LogTail")
	}
	if !v3.Untouched {
		t.Errorf("Row 3: expected Untouched to be true")
	}
	if !v3.CanTryAgain || !v3.CanRemove || !v3.CanRepair {
		t.Errorf("Row 3: expected all 3 actions enabled")
	}

	// Row 4: armed.json present, deployer-started present, state=deployed
	v4 := EvaluateRecovery(armed, true, LifecycleState{State: StateDeployed}, tempDir)
	if v4.Verdict != VerdictDeployed {
		t.Errorf("Row 4: got verdict %q, want %q", v4.Verdict, VerdictDeployed)
	}
	if !v4.Untouched {
		t.Errorf("Row 4: expected Untouched to be true")
	}

	// Row 5: armed.json present, deployer-started present, state=healthy
	v5 := EvaluateRecovery(armed, true, LifecycleState{State: StateHealthy}, tempDir)
	if v5.Verdict != VerdictHealthy {
		t.Errorf("Row 5: got verdict %q, want %q", v5.Verdict, VerdictHealthy)
	}
}

func TestFriendlySplashMessageForPhase(t *testing.T) {
	phases := []string{
		"ntfs-mounted",
		"scratch-setup",
		"network-wait",
		"bundle-ingest",
		"registry-preflight",
		"fisherman",
		"verification",
		"reboot",
		"unknown-phase",
	}
	for _, p := range phases {
		title, msg := friendlySplashMessageForPhase(p)
		if title == "" || msg == "" {
			t.Errorf("phase %q returned empty title (%q) or message (%q)", p, title, msg)
		}
	}
}

func TestReadLastLogLines(t *testing.T) {
	tempDir := t.TempDir()
	logDir := filepath.Join(tempDir, "logs")
	_ = os.MkdirAll(logDir, 0o755)
	logFile := filepath.Join(logDir, "deployer-last-journal.log")

	var sb strings.Builder
	for i := 1; i <= 50; i++ {
		sb.WriteString("log entry line\n")
	}
	_ = os.WriteFile(logFile, []byte(sb.String()), 0o644)

	lines := readLastLogLines(tempDir, 30)
	if len(lines) != 30 {
		t.Errorf("readLastLogLines returned %d lines, want 30", len(lines))
	}
}

func TestHashFile(t *testing.T) {
	tempDir := t.TempDir()
	testFile := filepath.Join(tempDir, "sample.bin")
	_ = os.WriteFile(testFile, []byte("hello world wootc recovery"), 0o644)

	h, err := hashFile(testFile)
	if err != nil {
		t.Fatalf("hashFile failed: %v", err)
	}
	if len(h) != 64 {
		t.Errorf("expected 64 hex characters for SHA-256, got %d (%q)", len(h), h)
	}
}

func TestHeadlessRecoverDispatch(t *testing.T) {
	if !isHeadlessInvocation([]string{"wootc.exe", "recover", "--status"}) {
		t.Errorf("isHeadlessInvocation should recognize recover")
	}
	rc := runHeadless([]string{"wootc.exe", "recover", "--status"})
	if rc != 0 {
		t.Errorf("headless recover --status returned code %d, want 0", rc)
	}
}
