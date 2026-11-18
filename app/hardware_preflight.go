package main

import (
	"context"
	"fmt"
	"path/filepath"
)

// preloadAndCheckImageHardware runs before any power-state, disk or boot
// change. Offline-first (docs/branding-and-distribution.md §3): it pulls the
// selected image to C:\wootc\bundle\oci while the user's working Windows
// network still exists, because the deployer initramfs has no Wi-Fi. A
// failed pull is fatal on purpose, so the user sees an error while Windows
// can still show one. It then compares this PC's hardware with the staged
// image. WOOTC_PRELOAD=0 (and an unbranded build) skips the pull; a shipped
// offline bundle for the same image is still checked.
func preloadAndCheckImageHardware(ctx context.Context, imageRef string, emit func(ProgressEvent)) error {
	if !shouldPreloadImage(effectiveBranding()) {
		if bundle := readBundleInfo(); bundle == nil || bundle.Image != imageRef {
			return nil
		}
	} else if err := stageImageBundle(ctx, imageRef, func(done, total int64) {
		pct := 2.0
		msg := displayStepLabel(StepInstallerDownloadingYourLinuxSystem) + "…"
		if total > 0 {
			pct += 2 * float64(done) / float64(total)
			msg = fmt.Sprintf("%s… %.1f of %.1f GB", displayStepLabel(StepInstallerDownloadingYourLinuxSystem),
				float64(done)/1e9, float64(total)/1e9)
		}
		emit(ProgressEvent{Step: StepInstallerDownloadingYourLinuxSystem, PhaseID: StepInstallerDownloadingYourLinuxSystem, Message: msg, Percent: pct})
	}); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	emit(ProgressEvent{
		Step: StepInstallerDownloadingYourLinuxSystem, PhaseID: StepInstallerDownloadingYourLinuxSystem,
		Message: "Checking the Linux image for this PC's hardware support…", Percent: 4,
	})
	return enforceHardwareCompatibility(assessStagedHardware(), StepInstallerDownloadingYourLinuxSystem, 4, emit)
}

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
