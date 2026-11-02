package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// checkImageHardware runs before any Windows configuration, root disk or boot
// changes. Image download and inspection only create ordinary bundle files.
func checkImageHardware(ctx context.Context, imageRef string, emit func(ProgressEvent)) error {
	notify := func(message string) {
		fmt.Fprintln(os.Stderr, "[wootc] "+message)
		if emit != nil {
			emit(ProgressEvent{Step: StepInstallerCheckingYourPC, PhaseID: StepInstallerCheckingYourPC, Message: message, Percent: 4})
		}
	}
	unknown := func(why string) hardwareReport {
		return hardwareReport{Image: imageRef, Findings: []hardwareFinding{{"warning", "Hardware compatibility could NOT be checked", why + ". Before rebooting, verify that the target supports your storage, graphics and network hardware."}}}
	}
	var report hardwareReport
	if !shouldPreloadImage(effectiveBranding()) {
		// Shipped offline bundles are inspectable even if network preload is off.
		bundle := readBundleInfo()
		if bundle == nil || bundle.Image != imageRef {
			report = unknown("No local target image is available (image preload is disabled)")
			return finishHardwarePreflight(report, "", notify)
		}
	} else {
		if err := stageImageBundle(ctx, imageRef, func(done, total int64) {
			pct := 2.0
			message := displayStepLabel(StepInstallerDownloadingYourLinuxSystem) + "…"
			if total > 0 {
				pct += 2 * float64(done) / float64(total)
				message = fmt.Sprintf("%s… %.1f of %.1f GB", displayStepLabel(StepInstallerDownloadingYourLinuxSystem), float64(done)/1e9, float64(total)/1e9)
			}
			if emit != nil {
				emit(ProgressEvent{Step: StepInstallerDownloadingYourLinuxSystem, PhaseID: StepInstallerDownloadingYourLinuxSystem, Message: message, Percent: pct})
			}
		}); err != nil {
			return err
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	devices, err := collectHardwareDevices(ctx)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		report = unknown(err.Error())
	} else {
		kernel, err := readHardwareInventory(ctx, filepath.Join(bundleDir(), "oci"), devices)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			report = unknown(err.Error())
		} else {
			report = assessHardware(devices, kernel)
			report.Image = imageRef
		}
	}
	return finishHardwarePreflight(report, filepath.Join(bundleDir(), "hardware-report.json"), notify)
}

func finishHardwarePreflight(report hardwareReport, reportPath string, notify func(string)) error {
	// This is an observation, not support-policy or release-green evidence.
	if reportPath != "" {
		data, err := json.MarshalIndent(report, "", "  ")
		if err == nil {
			err = os.WriteFile(reportPath, append(data, '\n'), 0600)
		}
		if err != nil {
			return fmt.Errorf("record hardware compatibility report: %w", err)
		}
	}
	blocked := []string{}
	for _, f := range report.Findings {
		message := fmt.Sprintf("Hardware compatibility %s — %s: %s", strings.ToUpper(f.Severity), f.Subject, f.Detail)
		notify(message)
		if f.Severity == "blocking" {
			blocked = append(blocked, f.Subject+": "+f.Detail)
		}
	}
	if len(blocked) > 0 {
		return fmt.Errorf("installation refused before disk or boot changes: %s", strings.Join(blocked, "; "))
	}
	if len(report.Findings) == 0 {
		notify(fmt.Sprintf("Hardware driver check: %d PCI devices matched kernel %s. This does not prove runtime hardware or firmware support.", report.DevicesChecked, report.TargetKernel))
	}
	return nil
}
