package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestStateTransitions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")

	states := []string{
		StateStaged,
		StateArmed,
		StateDeploying,
		StateDeployed,
		StateHealthy,
		StateFailed,
	}

	for _, st := range states {
		writeStateAt(path, st, "test-phase", "")
		s, ok := readStateFrom(path)
		if !ok {
			t.Fatalf("readState failed for state %q", st)
		}
		if s.State != st {
			t.Errorf("state = %q, want %q", s.State, st)
		}
		if s.Phase != "test-phase" {
			t.Errorf("phase = %q, want test-phase", s.Phase)
		}
	}
}

func TestReadStateFrom(t *testing.T) {
	tempDir := t.TempDir()
	p := filepath.Join(tempDir, "state.json")

	// Missing file
	if _, ok := readStateFrom(p); ok {
		t.Error("readStateFrom on missing file returned ok=true")
	}

	// Valid file
	data := []byte(`{"state":"deployed","updatedAt":"2026-09-02T12:00:00Z","updatedBy":"wootc-deployer"}`)
	if err := os.WriteFile(p, data, 0o644); err != nil {
		t.Fatal(err)
	}
	s, ok := readStateFrom(p)
	if !ok {
		t.Fatal("readStateFrom returned ok=false for valid file")
	}
	if s.State != StateDeployed || s.UpdatedBy != "wootc-deployer" {
		t.Errorf("readStateFrom = %+v, want deployed / wootc-deployer", s)
	}
}

func TestDeployHasCompletedLogic(t *testing.T) {
	tempDir := t.TempDir()
	stateFile := filepath.Join(tempDir, "state.json")
	logDir := filepath.Join(tempDir, "logs")
	_ = os.MkdirAll(logDir, 0o755)
	journalFile := filepath.Join(logDir, "deployer-last-journal.log")
	_ = os.WriteFile(journalFile, []byte("some failure logs"), 0o644)

	// Case 1: only journal exists, no state.json -> false
	if s, ok := readStateFrom(stateFile); ok && (s.State == StateDeployed || s.State == StateHealthy) {
		t.Error("expected false when state.json is absent")
	}

	// Case 2: state.json is armed -> false
	_ = os.WriteFile(stateFile, []byte(`{"state":"armed"}`), 0o644)
	if s, ok := readStateFrom(stateFile); ok && (s.State == StateDeployed || s.State == StateHealthy) {
		t.Error("expected false for armed state")
	}

	// Case 3: state.json is deploying -> false
	_ = os.WriteFile(stateFile, []byte(`{"state":"deploying"}`), 0o644)
	if s, ok := readStateFrom(stateFile); ok && (s.State == StateDeployed || s.State == StateHealthy) {
		t.Error("expected false for deploying state")
	}

	// Case 4: state.json is failed -> false
	_ = os.WriteFile(stateFile, []byte(`{"state":"failed","phase":"fisherman"}`), 0o644)
	if s, ok := readStateFrom(stateFile); ok && (s.State == StateDeployed || s.State == StateHealthy) {
		t.Error("expected false for failed state")
	}

	// Case 5: state.json is deployed -> true
	_ = os.WriteFile(stateFile, []byte(`{"state":"deployed"}`), 0o644)
	if s, ok := readStateFrom(stateFile); !ok || !(s.State == StateDeployed || s.State == StateHealthy) {
		t.Error("expected true for deployed state")
	}

	// Case 6: state.json is healthy -> true
	_ = os.WriteFile(stateFile, []byte(`{"state":"healthy"}`), 0o644)
	if s, ok := readStateFrom(stateFile); !ok || !(s.State == StateDeployed || s.State == StateHealthy) {
		t.Error("expected true for healthy state")
	}
}
