//go:build !windows

package main

import "fmt"

func readStatusState() (StatusReport, bool, error) {
	state, ok := readState()
	if !ok {
		return StatusReport{}, false, nil
	}
	return statusReportAt(wootcDir(), state), true, nil
}

// Native authenticated startup is a Windows-only entrypoint.
func auditTrustedStateDirectory(root string) error {
	return fmt.Errorf("native state audit requires Windows")
}
