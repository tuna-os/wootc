//go:build !windows

package main

import "fmt"

func readStatusState() (LifecycleState, bool, error) {
	state, ok := readState()
	return state, ok, nil
}

// Native authenticated startup is a Windows-only entrypoint.
func auditTrustedStateDirectory(root string) error {
	return fmt.Errorf("native state audit requires Windows")
}
