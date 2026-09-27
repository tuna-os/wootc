package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Status must not create a state directory or rewrite its permissions. Other
// entrypoints retain the installation boundary; status audits before reading.
func initializeStateTrustForInvocation(args []string) error {
	if len(args) > 1 && args[1] == "status" {
		return nil
	}
	return initializeStateTrust()
}

// A payload-only C: directory is not an installation. Conversely, surviving
// outputs from an interrupted attempt must not become an "absent" verdict.
// Never choose the first drive or newest timestamp when attempts compete.
func discoverStatusState(roots []string, audit func(string) error) (LifecycleState, string, bool, error) {
	var selected LifecycleState
	selectedRoot := ""
	for _, root := range roots {
		if _, err := os.Lstat(root); os.IsNotExist(err) {
			continue
		} else if err != nil {
			return LifecycleState{}, "", false, fmt.Errorf("inspect status location %s: %w", root, err)
		}
		if err := audit(root); err != nil {
			return LifecycleState{}, "", false, err
		}
		if !hasInstallAttempt(root) {
			continue
		}
		if selectedRoot != "" {
			return LifecycleState{}, "", false, fmt.Errorf("ambiguous installations at %s and %s", selectedRoot, root)
		}
		state, err := loadStatusState(filepath.Join(root, "state.json"))
		if err != nil {
			return LifecycleState{}, "", false, fmt.Errorf("installation at %s has no valid lifecycle state: %w", root, err)
		}
		selected, selectedRoot = state, root
	}
	return selected, selectedRoot, selectedRoot != "", nil
}

func loadStatusState(path string) (LifecycleState, error) {
	data, err := readBoundedStatusRecord(path)
	if err != nil {
		return LifecycleState{}, err
	}
	var state LifecycleState
	fields := map[string]string{"phaseId": "string", "state": "string", "phase": "string", "error": "string", "updatedAt": "string", "updatedBy": "string"}
	if err := decodeStrictStatusRecord(data, &state, fields, []string{"state", "updatedAt", "updatedBy"}); err != nil {
		return LifecycleState{}, err
	}
	switch state.State {
	case StateStaged, StateArmed, StateDeploying, StateDeployed, StateHealthy, StateFailed:
	default:
		return LifecycleState{}, fmt.Errorf("unknown lifecycle state %q", state.State)
	}
	if _, err := time.Parse(time.RFC3339, state.UpdatedAt); err != nil {
		return LifecycleState{}, fmt.Errorf("invalid lifecycle update date: %w", err)
	}
	if strings.TrimSpace(state.UpdatedBy) == "" {
		return LifecycleState{}, fmt.Errorf("missing lifecycle writer")
	}
	return state, nil
}

// Audit the existing tree without calling prepareTrustedStateTree, which
// creates directories and applies ACLs. WalkDir never follows symlinks.
func auditStatusTree(root string, inspect func(string) error) error {
	return filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		return inspect(path)
	})
}
