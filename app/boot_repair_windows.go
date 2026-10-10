//go:build windows

package main

import "strings"

// observeBoot gathers the evidence planBootRepair needs. Read-only.
func observeBoot() BootObservation {
	var obs BootObservation
	observeLocalState(&obs)
	out, err := runCmd("bcdedit", "/enum", "firmware")
	obs.FirmwareEnum = out
	if err != nil {
		obs.FirmwareEnumErr = strings.TrimSpace(err.Error() + " " + tail(out, 400))
	}
	espPath, err := findESP()
	if err != nil {
		obs.ESPErr = err.Error()
		return obs
	}
	observeESP(&obs, espPath)
	return obs
}

func runBCDEdit(args ...string) (string, error) {
	return runCmd("bcdedit", args...)
}
