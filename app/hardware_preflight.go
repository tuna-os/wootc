package main

import (
	"fmt"
	"path/filepath"
)

// assessStagedHardware compares Windows' active PnP devices with the image
// already downloaded for offline installation. Failure to inventory either
// side is an explicit warning, never a false compatibility pass or refusal.
func assessStagedHardware() HardwareReport {
	target, err := inspectOCIBundle(filepath.Join(bundleDir(), "oci"))
	if err != nil {
		return HardwareReport{Findings: []HardwareFinding{{
			Severity: HardwareWarning,
			Subject:  "hardware compatibility could not be checked",
			Detail:   fmt.Sprintf("%v. Installation may continue, but confirm that the image supports this PC's storage, network and graphics hardware before restarting.", err),
		}}}
	}
	return assessHardware(readHostHardware(), *target)
}

func enforceHardwareCompatibility(report HardwareReport, step string, percent float64, emit func(ProgressEvent)) error {
	if warnings := report.warningMessages(); len(warnings) > 0 {
		emit(ProgressEvent{
			Step: step, PhaseID: step, Message: "The hardware compatibility check found items to review.",
			Percent: percent, Warnings: warnings,
		})
	}
	return report.blockingError()
}
