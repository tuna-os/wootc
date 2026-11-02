package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// installRunner is the application-facing boundary for privileged installation.
// The Wails façade owns lifecycle and events; this service owns execution.
type installRunner interface {
	Run(context.Context, InstallConfig, func(ProgressEvent)) error
}

// installPlatform supplies operating-system effects to the install engine.
// Keeping these effects behind one adapter lets the engine test ordering,
// cancellation, and rollback without constructing a Wails App.
type installPlatform interface {
	prepare(string) (func(), error)
	steps(context.Context, InstallConfig, func(ProgressEvent)) []installPipelineStep
	newJournal(InstallConfig) *installJournalRecorder
	writeState(string, string, string)
	disarmOneShot()
}

type installEngine struct {
	platform installPlatform
}

type windowsInstallPlatform struct{}

func newInstallEngine() *installEngine {
	return &installEngine{platform: windowsInstallPlatform{}}
}

func (windowsInstallPlatform) prepare(storageDrive string) (func(), error) {
	if err := prepareInstallState(storageDrive); err != nil {
		return nil, err
	}
	release, err := acquireNativeInstallLease(wootcDir())
	if err != nil {
		return nil, err
	}
	if err := requireNewInstallRootDisk(); err != nil {
		release()
		return nil, err
	}
	if err := discardStaleFirstBootEvidence(wootcDir()); err != nil {
		release()
		return nil, err
	}
	return release, nil
}

func (windowsInstallPlatform) steps(ctx context.Context, cfg InstallConfig, emit func(ProgressEvent)) []installPipelineStep {
	return productionInstallSteps(ctx, cfg, emit)
}

func (windowsInstallPlatform) newJournal(cfg InstallConfig) *installJournalRecorder {
	return newInstallJournalRecorder(journalPath(), cfg, nil)
}

func (windowsInstallPlatform) writeState(state, phase, errMsg string) {
	writeState(state, phase, errMsg)
}

func (windowsInstallPlatform) disarmOneShot() {
	disarmOneShot()
}

type installPipelineStep struct {
	name    string
	percent float64
	fn      func() error
}

// Build the real ordered pipeline without executing its operations.
func productionInstallSteps(ctx context.Context, cfg InstallConfig, emit func(ProgressEvent)) []installPipelineStep {
	return []installPipelineStep{
		{StepInstallerCheckingYourPC, 2, func() error { return checkSystem() }},
		{StepInstallerPreparingWindows, 5, func() error { return disableFastStartup() }},
		{StepInstallerSettingThingsUp, 8, func() error { return createDirectories() }},
		// Resolve where the user's files ACTUALLY live while Windows is still
		// running and can read its own registry (#64). Best-effort: on a machine
		// with no redirection nothing is lost if this fails, and the Phase-2
		// bridge falls back to the literal profile layout.
		{StepInstallerFindingYourFiles, 9, func() error { recordKnownFolders(); return nil }},
		{StepInstallerMakingRoomForLinux, 15, func() error { return createRootDisk(cfg.DiskSizeGB) }},
		{StepInstallerDownloadingLinux, 50, func() error {
			return downloadDeployer(ctx, func(p float64) {
				emit(ProgressEvent{
					Step:    StepInstallerDownloadingLinux,
					PhaseID: StepInstallerDownloadingLinux,
					Message: fmt.Sprintf("%s… %.0f%%", displayStepLabel(StepInstallerDownloadingLinux), p*35),
					Percent: 15 + p*35,
				})
			})
		}},
		{StepInstallerDownloadingYourLinuxSystem, 54, func() error {
			// Offline-first (docs/branding-and-distribution.md §3): pull the
			// selected image to C:\wootc\bundle\oci while the user's working
			// Windows network still exists — the deployer initramfs has no
			// Wi-Fi and must not need one. On for every brand that sets
			// preloadImage (all branded builds); the generic build can opt in
			// with WOOTC_PRELOAD=1 until the offline matrix axis proves it
			// everywhere. Failing here is fatal ON PURPOSE: this machine's
			// network already failed while Windows could still say so —
			// discovering that after the reboot would strand the user at a
			// splash screen instead of an error they can act on.
			// WOOTC_PRELOAD=0 force-disables even for branded builds: the
			// E2E harness runs BRANDED exes (the walkthrough videos must
			// show the installer users actually get) but the offline bundle
			// path has its own matrix axis (#217) — until that is green,
			// the harness proves branding and deploy separately from
			// preload. Real users never run with this variable set.
			if !shouldPreloadImage(effectiveBranding()) {
				return nil
			}
			if err := stageImageBundle(ctx, cfg.ImageRef, func(done, total int64) {
				pct := 50.0
				msg := displayStepLabel(StepInstallerDownloadingYourLinuxSystem) + "…"
				if total > 0 {
					pct = 50 + 4*float64(done)/float64(total)
					msg = fmt.Sprintf("%s… %.1f of %.1f GB", displayStepLabel(StepInstallerDownloadingYourLinuxSystem),
						float64(done)/1e9, float64(total)/1e9)
				}
				emit(ProgressEvent{Step: StepInstallerDownloadingYourLinuxSystem, PhaseID: StepInstallerDownloadingYourLinuxSystem, Message: msg, Percent: pct})
			}); err != nil {
				return err
			}
			emit(ProgressEvent{
				Step: StepInstallerDownloadingYourLinuxSystem, PhaseID: StepInstallerDownloadingYourLinuxSystem,
				Message: "Checking the Linux image for this PC's hardware support…", Percent: 54,
			})
			return enforceHardwareCompatibility(
				assessStagedHardware(), StepInstallerDownloadingYourLinuxSystem, 54, emit,
			)
		}},
		{StepInstallerPreparingTheStartupMenu, 55, func() error { return writeGrubConfig(cfg) }},
		{StepInstallerGettingLinuxPrepared, 65, func() error { return setupESP(cfg) }},
		{StepInstallerMakingLinuxBootableOnYourMachine, 80, func() error { return configureBCD(cfg) }},
		{StepInstallerSavingYourSettings, 85, func() error { return writeVault(cfg) }},
		{StepInstallerSavingYourBitLockerRecoveryKey, 87, func() error {
			// When C: is BitLocker-protected, capture the numerical recovery
			// password so Phase 2 (Linux) can unlock C: and the User Data
			// Bridge can find the user profiles that live there (#61).
			// This is a best-effort step: if the key cannot be extracted
			// the install still proceeds, but the bridge will report that
			// profiles are on an encrypted volume and could not be reached.
			key := captureBitLockerRecoveryKey("C:")
			if key != "" {
				if err := writeBitLockerKey(key); err != nil {
					fmt.Fprintf(os.Stderr, "[wootc] warning: could not store BitLocker recovery key: %v\n", err)
				}
			}
			return nil
		}},
		{StepInstallerLookingAtYourInstalledApps, 82, func() error {
			// Registry-based program inventory (§4.3): enumerate HKLM/HKCU
			// uninstall keys before Windows goes away, so the migration
			// dashboard can show the complete picture — not just apps with
			// an AppData footprint. Best-effort: never fail install.
			if err := collectPrograms(); err != nil {
				fmt.Fprintf(os.Stderr, "[wootc] program collection skipped: %v\n", err)
			}
			return nil
		}},
		{StepInstallerCheckingYourSignedInApps, 90, func() error {
			candidates, err := collectSessions()
			if err != nil {
				fmt.Fprintf(os.Stderr, "[wootc] session collection skipped: %v\n", err)
				return nil
			}
			results := exportConsentedSessions(candidates, cfg.SessionConsent, cfg.Password)
			for _, result := range results {
				if result.State == "failed" {
					fmt.Fprintf(os.Stderr, "[wootc] %s session export failed: %s\n", result.App, result.Reason)
				}
			}
			// This is deliberately a status ledger, not a success marker. The
			// target-side importer must replace "staged" with "imported" before
			// any UI can describe the app as signed in.
			path := filepath.Join(wootcDir(), "install", "slurp", "session", "exports.json")
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				fmt.Fprintf(os.Stderr, "[wootc] session export ledger directory skipped: %v\n", err)
				return nil
			}
			if err := os.WriteFile(path, []byte(sessionExportSummary(results)), 0o600); err != nil {
				fmt.Fprintf(os.Stderr, "[wootc] session export ledger skipped: %v\n", err)
			}
			return nil
		}},
		{StepInstallerLookingForYourCloudDrives, 88, func() error {
			// Cloud-storage detection (#66): OneDrive, Google Drive and
			// Dropbox. Google Drive lives at a virtual drive letter (G:)
			// produced by DriveFS at runtime — from Linux, reading the
			// physical disk, it does not exist. The manifest tells the
			// Phase-2 bridge which rclone remotes to provision.
			// Best-effort: never fail install.
			recordCloudDrives()
			return nil
		}},
		{StepInstallerCollectingYourLookAndWiFi, 92, func() error {
			// Wi-Fi profiles (§4.6) migrate UNCONDITIONALLY: recreated as
			// NetworkManager connections on first boot, so the user is online
			// without re-typing a single password — the friendliest thing a
			// migration can do, and safe. This used to hide inside the
			// WindowsLook gate below, which the GUI additionally never sent
			// (the field was dropped from StartInstall's payload), so no real
			// install ever brought Wi-Fi along. Best-effort: never fail the
			// install over either collection.
			if err := collectWifi(); err != nil {
				fmt.Fprintf(os.Stderr, "[wootc] wifi export skipped: %v\n", err)
			}
			// Windows-Style Mode (SPEC §4.4) is on by default and opt-out in
			// the GUI. When declined we collect nothing and the deployed
			// system keeps the image maker's desktop defaults — no slurp data
			// means apply-look no-ops on first login.
			if cfg.WindowsLook {
				if err := collectLook(); err != nil {
					fmt.Fprintf(os.Stderr, "[wootc] look collection skipped: %v\n", err)
				}
			}
			return nil
		}},
		{StepInstallerFinishingUp, 96, func() error {
			// Discoverability: an Add/Remove Programs entry so "how do I
			// remove this?" has the answer Windows users actually look for
			// (best-effort, removed again by uninstall).
			registerUninstallEntry()
			// Small deliberate pause so the user sees "done"
			time.Sleep(500 * time.Millisecond)
			// Commit point of the boot-chain transaction (#286): the one-shot
			// is the LAST change before reboot. Until here the wootc entry is
			// inert, so a cancel, failure, or power cut at any earlier step
			// returns to Windows.
			return armBootChain()
		}},
	}

}

// Run executes install steps, reporting progress through emit.
// It is shared between the GUI (Wails events) and headless mode (stdout),
// so E2E can exercise the exact production pipeline without a display.
func (e *installEngine) Run(ctx context.Context, cfg InstallConfig, emit func(ProgressEvent)) error {
	release, err := e.platform.prepare(cfg.StorageDrive)
	if err != nil {
		return err
	}
	defer release()
	steps := e.platform.steps(ctx, cfg, emit)
	// Started only after the gates above, so a refused run never overwrites
	// the journal of the attempt recovery still has to explain.
	journal := e.platform.newJournal(cfg)

	fault := cfg.FaultInject
	if fault == "" {
		fault = os.Getenv("WOOTC_FAULT_INJECT")
	}

	// Track whether the one-shot boot entry is armed. From "Making Linux
	// bootable on your machine" (configureBCD) onward, a failure or a
	// cancel must DISARM it — otherwise a user who changed their mind, or
	// hit an error at 85%, still gets a surprise Linux boot attempt on the
	// next restart, while the UI is telling them "nothing permanent
	// changes" (North Star audit 2026-08-22).
	armed := false
	for _, s := range steps {
		select {
		case <-ctx.Done():
			if armed {
				e.platform.disarmOneShot()
			}
			e.platform.writeState(StateStaged, "cancelled", "")
			journal.end(JournalCancelled, "")
			return ctx.Err()
		default:
		}
		journal.stepStarted(s.name)
		emit(installStepProgress(s.name, s.percent))

		if fault != "" {
			switch {
			case fault == "root-disk" && s.name == StepInstallerMakingRoomForLinux:
				if armed {
					e.platform.disarmOneShot()
				}
				e.platform.writeState(StateFailed, s.name, "fault-injection: simulated failure during root disk creation")
				journal.end(JournalFailed, "fault-injection: simulated failure during root disk creation")
				return fmt.Errorf("%s: fault-injection: simulated failure during root disk creation", displayStepLabel(s.name))
			case (fault == "image-pull" || fault == "image-download") && (s.name == StepInstallerDownloadingLinux || s.name == StepInstallerDownloadingYourLinuxSystem):
				if armed {
					e.platform.disarmOneShot()
				}
				e.platform.writeState(StateFailed, s.name, "fault-injection: simulated failure during image download")
				journal.end(JournalFailed, "fault-injection: simulated failure during image download")
				return fmt.Errorf("%s: fault-injection: simulated failure during image download", displayStepLabel(s.name))
			case (fault == "efi-staging" || fault == "efi") && s.name == StepInstallerGettingLinuxPrepared:
				if armed {
					e.platform.disarmOneShot()
				}
				e.platform.writeState(StateFailed, s.name, "fault-injection: simulated failure during EFI staging")
				journal.end(JournalFailed, "fault-injection: simulated failure during EFI staging")
				return fmt.Errorf("%s: fault-injection: simulated failure during EFI staging", displayStepLabel(s.name))
			case (fault == "bcd-arming" || fault == "bcd") && s.name == StepInstallerMakingLinuxBootableOnYourMachine:
				if armed {
					e.platform.disarmOneShot()
				}
				e.platform.writeState(StateFailed, s.name, "fault-injection: simulated failure during BCD arming")
				journal.end(JournalFailed, "fault-injection: simulated failure during BCD arming")
				return fmt.Errorf("%s: fault-injection: simulated failure during BCD arming", displayStepLabel(s.name))
			}
		}

		// Set BEFORE the step runs: configureBCD can fail after it created an
		// entry, and that partial chain must be rolled back too.
		if s.name == StepInstallerMakingLinuxBootableOnYourMachine {
			armed = true
		}
		if err := s.fn(); err != nil {
			if armed {
				e.platform.disarmOneShot()
			}
			e.platform.writeState(StateFailed, s.name, err.Error())
			journal.end(JournalFailed, err.Error())
			return fmt.Errorf("%s: %w", displayStepLabel(s.name), err)
		}
		journal.stepDone(s.name)
	}

	if fault == "pre-reboot" {
		if armed {
			e.platform.disarmOneShot()
		}
		e.platform.writeState(StateStaged, "cancelled", "fault-injection: simulated cancellation before reboot")
		journal.end(JournalCancelled, "fault-injection: simulated cancellation before reboot")
		return fmt.Errorf("fault-injection: simulated cancellation before reboot")
	}

	if err := finishInstallPipeline(ctx, armed, e.platform.disarmOneShot, e.platform.writeState); err != nil {
		journal.end(JournalCancelled, "")
		return err
	}
	journal.end(JournalArmed, "")
	return nil
}

// A cancellation can arrive inside the final synchronous operation. There is
// no next loop iteration to observe it, so check again before claiming success.
func finishInstallPipeline(ctx context.Context, armed bool, disarm func(), persist func(string, string, string)) error {
	if err := ctx.Err(); err != nil {
		if armed {
			disarm()
		}
		persist(StateStaged, "cancelled", "")
		return err
	}
	persist(StateArmed, "", "")
	return nil
}
