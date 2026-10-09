//go:build !windows

package main

import "fmt"

// observeBoot has no boot configuration to read outside Windows. The
// firmware error makes every BCD action refuse, which is the honest answer.
func observeBoot() BootObservation {
	var obs BootObservation
	observeLocalState(&obs)
	obs.FirmwareEnumErr = "the Windows boot configuration is only readable on Windows"
	obs.ESPErr = "the EFI system partition is only located on Windows"
	return obs
}

func runBCDEdit(args ...string) (string, error) {
	return "", fmt.Errorf("bcdedit is only available on Windows")
}
