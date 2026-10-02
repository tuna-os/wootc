package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// ── Interrupted-install recovery (#287, parent #285) ────────────────────────
// On relaunch wootc classifies the last attempt from durable evidence — the
// install journal, state.json, the armed/deployer markers, the startup
// verdict, the staged download and root.disk — and offers only the actions
// that evidence makes safe. classifyInstall is pure so every row of the table
// is reachable from tests; observeInstallAt does the reading.

const (
	InstallClassNone        = "none"        // no attempt on record
	InstallClassComplete    = "complete"    // armed and waiting for restart, deployed, or healthy
	InstallClassInProgress  = "in-progress" // another live wootc process owns the attempt
	InstallClassResumable   = "resumable"   // stopped cleanly or interrupted; nothing half-written at boot level
	InstallClassFailed      = "failed"      // a step reported an error
	InstallClassNeedsRepair = "needs-repair"
)

const (
	CauseCancelled           = "cancelled"   // the user cancelled
	CauseInterrupted         = "interrupted" // process gone with the journal still "running"
	CauseStepFailed          = "step-failed"
	CauseNeverBooted         = "never-booted" // armed, but Windows came back without the deployer starting
	CauseDeployerInterrupted = "deployer-interrupted"
	CauseDeployerFailed      = "deployer-failed"
	CauseAwaitingRestart     = "awaiting-restart"
	CauseDeployed            = "deployed"
	CauseHealthy             = "healthy"
	CauseUnknown             = "unknown"
)

// partialRootDiskSlack tolerates clock and timestamp granularity when
// checking that root.disk was created by the journaled attempt.
const partialRootDiskSlack = 2 * time.Minute

// BundleEvidence describes the image download staged under C:\wootc\bundle.
type BundleEvidence struct {
	Complete      bool   `json:"complete"`        // bundle.json + layout for the journaled image
	Image         string `json:"image,omitempty"` // image named by bundle.json
	VerifiedBlobs int    `json:"verifiedBlobs"`   // digest-named blobs (written only after verification)
	VerifiedBytes int64  `json:"verifiedBytes"`   // their total size
	PartialFiles  int    `json:"partialFiles"`    // *.part files: unverified, re-downloaded on resume
	Error         string `json:"error,omitempty"` // why the blob directory could not be read
}

// InstallObservation is everything classifyInstall looks at. It is the
// evidence the recovery screen and `recover --classify` print.
type InstallObservation struct {
	Journal         *InstallJournal `json:"journal,omitempty"`
	JournalError    string          `json:"journalError,omitempty"`
	JournalOwnerUp  bool            `json:"journalOwnerAlive"`
	State           *LifecycleState `json:"state,omitempty"`
	ArmedFile       bool            `json:"armedFile"`
	DeployerStarted bool            `json:"deployerStarted"`
	VerdictFile     bool            `json:"verdictFile"`
	Bundle          BundleEvidence  `json:"bundle"`
	RootDisk        bool            `json:"rootDisk"`
	RootDiskModTime string          `json:"rootDiskModTime,omitempty"`
}

// InstallRecoveryActions are the recovery choices the evidence allows.
type InstallRecoveryActions struct {
	// ResumeInstall: go back to the launchpad and run Phase 1 again. Verified
	// image blobs are reused; a root.disk this attempt created (and the
	// deployer never touched) is discarded first.
	ResumeInstall bool `json:"resumeInstall"`
	// RetryDeploy: re-arm the one-shot boot into the deployer (TryAgain).
	RetryDeploy bool `json:"retryDeploy"`
	// RepairBoot: re-stage and re-arm the recorded boot chain (RepairBoot).
	RepairBoot bool `json:"repairBoot"`
	// Remove: uninstall, which restores the boot configuration and power
	// settings and deletes the install folder.
	Remove bool `json:"remove"`
}

// InstallRecovery is the classification shown on relaunch.
type InstallRecovery struct {
	Class              string                 `json:"class"`
	Cause              string                 `json:"cause,omitempty"`
	ImageRef           string                 `json:"imageRef,omitempty"`
	LastCompletedStep  string                 `json:"lastCompletedStep,omitempty"`
	StoppedAtStep      string                 `json:"stoppedAtStep,omitempty"`
	Error              string                 `json:"error,omitempty"`
	Title              string                 `json:"title,omitempty"`
	Message            string                 `json:"message,omitempty"`
	Actions            InstallRecoveryActions `json:"actions"`
	Recommended        string                 `json:"recommended,omitempty"` // resume | retry-deploy | repair-boot | remove
	DiscardsRootDisk   bool                   `json:"discardsRootDisk"`      // ResumeInstall will delete the partial root.disk
	KeepsVerifiedBlobs int                    `json:"keepsVerifiedBlobs"`
	KeepsVerifiedBytes int64                  `json:"keepsVerifiedBytes"`
	Evidence           []string               `json:"evidence"`
	Observation        InstallObservation     `json:"observation"`
}

// bootChainSteps change the ESP or the firmware boot entries. An attempt that
// reached one of them without finishing Phase 1 leaves boot artifacts behind.
func bootChainTouched(j InstallJournal) bool {
	for _, s := range []string{StepInstallerGettingLinuxPrepared, StepInstallerMakingLinuxBootableOnYourMachine} {
		if j.CurrentStep == s || j.Completed(s) {
			return true
		}
	}
	return false
}

func rootDiskStepReached(j InstallJournal) bool {
	return j.CurrentStep == StepInstallerMakingRoomForLinux || j.Completed(StepInstallerMakingRoomForLinux)
}

// partialRootDiskOwned reports whether root.disk is provably this attempt's
// own, never-deployed file: the journal starts only after the gate that
// refuses an existing root.disk, the attempt reached "Making room for Linux",
// the deployer never started, and the file is not older than the attempt.
// Anything less and root.disk may hold someone's Linux, so it is kept.
func partialRootDiskOwned(o InstallObservation) bool {
	j := o.Journal
	if j == nil || !o.RootDisk || o.DeployerStarted || o.ArmedFile || !rootDiskStepReached(*j) {
		return false
	}
	if o.State != nil {
		switch o.State.State {
		case StateDeploying, StateDeployed, StateHealthy:
			return false
		}
	}
	started, err := time.Parse(time.RFC3339, j.StartedAt)
	if err != nil {
		return false
	}
	mod, err := time.Parse(time.RFC3339, o.RootDiskModTime)
	if err != nil {
		return false
	}
	return !mod.Before(started.Add(-partialRootDiskSlack))
}

// classifyInstall turns an observation into a recovery decision.
func classifyInstall(o InstallObservation) InstallRecovery {
	r := InstallRecovery{Observation: o, Evidence: installEvidence(o)}
	if o.Journal != nil {
		r.ImageRef = o.Journal.ImageRef
		r.LastCompletedStep = o.Journal.LastCompletedStep()
	}
	stateName := ""
	if o.State != nil {
		stateName = o.State.State
	}
	armedActions := func() {
		r.Actions.RetryDeploy = o.ArmedFile
		r.Actions.RepairBoot = o.ArmedFile
		r.Actions.Remove = true
		r.Recommended = "remove"
		if o.ArmedFile {
			r.Recommended = "retry-deploy"
		}
	}

	// Phase 2: the deployer's own record wins over anything Phase 1 wrote.
	switch {
	case stateName == StateHealthy:
		r.Class, r.Cause = InstallClassComplete, CauseHealthy
		r.Title = "Linux is installed"
		r.Message = "The new system started and reported that it is healthy."
		return r
	case stateName == StateDeployed:
		r.Class, r.Cause = InstallClassComplete, CauseDeployed
		r.Title = "Linux is installed"
		r.Message = "The new system is ready. It finishes setting up the next time it starts."
		r.Actions.Remove = true
		return r
	case stateName == StateDeploying:
		r.Class, r.Cause = InstallClassResumable, CauseDeployerInterrupted
		r.StoppedAtStep = observedStepID(o.State.PhaseID)
		if r.StoppedAtStep == "" {
			r.StoppedAtStep = observedStepID(o.State.Phase)
		}
		r.Title = "Setup stopped while installing Linux"
		r.Message = "The computer restarted or lost power while the installer was running. Windows is still the default system. Try again to run the installer once more."
		armedActions()
		return r
	case stateName == StateFailed && o.DeployerStarted:
		r.Class, r.Cause = InstallClassFailed, CauseDeployerFailed
		r.StoppedAtStep = observedStepID(o.State.PhaseID)
		if r.StoppedAtStep == "" {
			r.StoppedAtStep = observedStepID(o.State.Phase)
		}
		r.Error = o.State.Error
		r.Title = "The Linux installer reported an error"
		r.Message = "Windows is still the default system. Try again, repair the startup entry, or remove the installation."
		armedActions()
		return r
	}

	// Phase 1 finished: armed and waiting for (or past) the restart.
	if (o.Journal != nil && o.Journal.Outcome == JournalArmed) || (o.Journal == nil && stateName == StateArmed) {
		if o.VerdictFile && !o.DeployerStarted {
			r.Class, r.Cause = InstallClassResumable, CauseNeverBooted
			r.Title = "Windows started instead of the Linux installer"
			r.Message = "The computer did not start the installer after the restart. Nothing was installed yet. Try again to restart into it."
			armedActions()
			return r
		}
		r.Class, r.Cause = InstallClassComplete, CauseAwaitingRestart
		r.Title = "Ready to restart"
		r.Message = "Preparation finished. Restart the computer to install Linux."
		r.Actions.Remove = true
		return r
	}

	if o.Journal == nil {
		return classifyWithoutJournal(r, o)
	}

	j := *o.Journal
	r.StoppedAtStep = j.CurrentStep
	r.Error = j.Error
	switch j.Outcome {
	case JournalRunning:
		if o.JournalOwnerUp {
			r.Class, r.Cause = InstallClassInProgress, ""
			r.Title = "An installation is running"
			r.Message = "Another wootc window is installing right now. Wait for it to finish."
			return r
		}
		r.Cause = CauseInterrupted
	case JournalCancelled:
		r.Cause = CauseCancelled
	case JournalFailed:
		r.Cause = CauseStepFailed
	default:
		r.Class, r.Cause = InstallClassNeedsRepair, CauseUnknown
		r.Title = "The last installation left an unknown record"
		r.Message = "Remove the installation before you try again."
		r.Actions.Remove = true
		r.Recommended = "remove"
		return r
	}

	if bootChainTouched(j) {
		// ESP files or a firmware entry may exist without a finished
		// Phase 1. Re-running the pipeline over them is not proven
		// idempotent, so the safe path is to remove first. Repair is
		// offered only when armed.json records a chain to re-stage.
		r.Class = InstallClassNeedsRepair
		r.Actions.Remove = true
		r.Actions.RepairBoot = o.ArmedFile
		r.Recommended = "remove"
		r.Title = "Setup stopped while changing the startup files"
		switch r.Cause {
		case CauseInterrupted:
			r.Message = "The computer restarted or wootc closed unexpectedly while it was changing the startup files. Remove the installation to put the startup files back, then install again."
		case CauseCancelled:
			r.Message = "You cancelled after wootc changed the startup files. The one-time Linux start was turned off. Remove the installation to clean up the startup files, then install again."
		default:
			r.Message = "A step failed after wootc changed the startup files. The one-time Linux start was turned off. Remove the installation to clean up the startup files, then install again."
		}
		return r
	}

	r.Actions.ResumeInstall = true
	r.Actions.Remove = true
	r.Recommended = "resume"
	r.KeepsVerifiedBlobs = o.Bundle.VerifiedBlobs
	r.KeepsVerifiedBytes = o.Bundle.VerifiedBytes
	if o.RootDisk {
		if partialRootDiskOwned(o) {
			r.DiscardsRootDisk = true
		} else {
			// A root.disk wootc cannot prove is this attempt's own blocks
			// a new install (requireNewInstallRootDisk), and it is never
			// deleted on a guess.
			r.Actions.ResumeInstall = false
			r.Recommended = "remove"
		}
	}
	switch r.Cause {
	case CauseInterrupted:
		r.Class = InstallClassResumable
		r.Title = "Setup stopped unexpectedly"
		r.Message = "wootc closed or the computer lost power before setup finished. Nothing outside the installation folder changed, and Windows starts as usual."
	case CauseCancelled:
		r.Class = InstallClassResumable
		r.Title = "You cancelled the last installation"
		r.Message = "Nothing outside the installation folder changed, and Windows starts as usual."
	default:
		r.Class = InstallClassFailed
		r.Title = "The last installation did not finish"
		r.Message = "A step failed. Nothing outside the installation folder changed, and Windows starts as usual."
	}
	return r
}

// classifyWithoutJournal handles records left by builds that predate the
// journal: state.json alone cannot tell a cancel from a crash, so the
// decision stays conservative.
func classifyWithoutJournal(r InstallRecovery, o InstallObservation) InstallRecovery {
	if o.State == nil {
		r.Class = InstallClassNone
		return r
	}
	switch o.State.State {
	case StateFailed, StateStaged:
		r.StoppedAtStep = observedStepID(o.State.PhaseID)
		r.Error = o.State.Error
		r.Cause = CauseStepFailed
		r.Class = InstallClassFailed
		if o.State.State == StateStaged && o.State.Phase == "cancelled" {
			r.Cause, r.Class, r.StoppedAtStep = CauseCancelled, InstallClassResumable, ""
		} else if o.State.State == StateStaged {
			// Staged without a cancel marker is either a run in progress
			// or one killed mid-way. Without a journal it is unknowable.
			r.Cause = CauseUnknown
		}
		r.Title = "The last installation did not finish"
		r.Message = "This record comes from an older wootc. Remove the installation if a new install will not start."
		r.Actions.Remove = true
		r.Actions.ResumeInstall = !o.RootDisk && !o.ArmedFile
		r.Recommended = "remove"
		if r.Actions.ResumeInstall {
			r.Recommended = "resume"
		}
		r.KeepsVerifiedBlobs = o.Bundle.VerifiedBlobs
		r.KeepsVerifiedBytes = o.Bundle.VerifiedBytes
		return r
	}
	r.Class = InstallClassNone
	return r
}

// installEvidence lists the facts the decision used, in plain words.
func installEvidence(o InstallObservation) []string {
	var ev []string
	switch {
	case o.Journal != nil:
		j := o.Journal
		line := fmt.Sprintf("journal.json: attempt %s, outcome %q, %d steps finished", j.AttemptID, j.Outcome, len(j.CompletedSteps))
		if j.CurrentStep != "" {
			line += fmt.Sprintf(", stopped in %q", j.CurrentStep)
		}
		if j.Outcome == JournalRunning {
			if o.JournalOwnerUp {
				line += fmt.Sprintf(", process %d still running", j.PID)
			} else {
				line += fmt.Sprintf(", process %d no longer running", j.PID)
			}
		}
		ev = append(ev, line)
	case o.JournalError != "":
		ev = append(ev, "journal.json unreadable: "+o.JournalError)
	default:
		ev = append(ev, "journal.json absent")
	}
	if o.State != nil {
		line := fmt.Sprintf("state.json: %s", o.State.State)
		if o.State.Phase != "" {
			line += fmt.Sprintf(" (%s)", o.State.Phase)
		}
		ev = append(ev, line)
	} else {
		ev = append(ev, "state.json absent")
	}
	ev = append(ev,
		fmt.Sprintf("armed.json %s", presentWord(o.ArmedFile)),
		fmt.Sprintf("deployer-started.json %s", presentWord(o.DeployerStarted)),
		fmt.Sprintf("recovery-verdict.json %s", presentWord(o.VerdictFile)),
	)
	b := o.Bundle
	switch {
	case b.Complete:
		ev = append(ev, fmt.Sprintf("download complete for %s", b.Image))
	case b.Error != "":
		ev = append(ev, "download folder unreadable: "+b.Error)
	default:
		ev = append(ev, fmt.Sprintf("download incomplete: %d verified pieces (%.1f GB), %d unverified partial files", b.VerifiedBlobs, float64(b.VerifiedBytes)/1e9, b.PartialFiles))
	}
	if o.RootDisk {
		ev = append(ev, "root.disk present, modified "+o.RootDiskModTime)
	} else {
		ev = append(ev, "root.disk absent")
	}
	return ev
}

func presentWord(b bool) string {
	if b {
		return "present"
	}
	return "absent"
}

// observeBundleAt inspects the OCI layout written by stageImageBundle. Blob
// files carry their digest as their name and are renamed into place only
// after the digest matched, so a digest-named file is a verified piece.
func observeBundleAt(dir, imageRef string) BundleEvidence {
	var ev BundleEvidence
	if b := readBundleInfoAt(dir); b != nil {
		ev.Image = b.Image
		ev.Complete = imageRef == "" || b.Image == imageRef
	}
	entries, err := os.ReadDir(filepath.Join(dir, "oci", "blobs", "sha256"))
	if err != nil {
		if !os.IsNotExist(err) {
			ev.Error = err.Error()
		}
		return ev
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasSuffix(name, ".part") {
			ev.PartialFiles++
			continue
		}
		if len(name) != 64 || strings.Trim(name, "0123456789abcdef") != "" {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		ev.VerifiedBlobs++
		ev.VerifiedBytes += info.Size()
	}
	return ev
}

// observeInstallAt reads every recovery input under a wootc data directory.
func observeInstallAt(dir string, alive func(pid int) bool) InstallObservation {
	var o InstallObservation
	install := filepath.Join(dir, "install")
	if j, ok, err := readJournalAt(filepath.Join(install, "journal.json")); err != nil {
		o.JournalError = err.Error()
	} else if ok {
		o.Journal = &j
		if j.Outcome == JournalRunning && j.PID > 0 && alive != nil {
			o.JournalOwnerUp = alive(j.PID)
		}
	}
	if s, ok := readStateFrom(filepath.Join(dir, "state.json")); ok {
		o.State = &s
	}
	o.ArmedFile = pathExists(filepath.Join(install, "armed.json"))
	o.DeployerStarted = pathExists(filepath.Join(install, "deployer-started.json"))
	o.VerdictFile = pathExists(filepath.Join(install, "recovery-verdict.json"))
	imageRef := ""
	if o.Journal != nil {
		imageRef = o.Journal.ImageRef
	}
	o.Bundle = observeBundleAt(filepath.Join(dir, "bundle"), imageRef)
	if st, err := os.Stat(filepath.Join(dir, "disks", "root.disk")); err == nil {
		o.RootDisk = true
		o.RootDiskModTime = st.ModTime().UTC().Format(time.RFC3339)
	}
	return o
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// inspectInstallRecovery classifies the attempt recorded under wootcDir().
func inspectInstallRecovery() InstallRecovery {
	return classifyInstall(observeInstallAt(wootcDir(), processAlive))
}

// ResumePreparation reports what prepareResumeAt changed.
type ResumePreparation struct {
	DiscardedRootDisk bool   `json:"discardedRootDisk"`
	KeptVerifiedBlobs int    `json:"keptVerifiedBlobs"`
	KeptVerifiedBytes int64  `json:"keptVerifiedBytes"`
	ImageRef          string `json:"imageRef,omitempty"`
}

// prepareResumeAt clears the way for a new Phase-1 run after a stop the
// classifier calls resumable or failed. It re-observes instead of trusting
// what the UI showed, deletes only a root.disk proven to be this attempt's
// own, and keeps every verified download piece for stageImageBundle to reuse.
func prepareResumeAt(dir string, alive func(pid int) bool) (ResumePreparation, error) {
	r := classifyInstall(observeInstallAt(dir, alive))
	if !r.Actions.ResumeInstall {
		return ResumePreparation{}, fmt.Errorf("resume is not safe for this installation (%s, %s); remove it first", r.Class, r.Cause)
	}
	p := ResumePreparation{
		KeptVerifiedBlobs: r.KeepsVerifiedBlobs,
		KeptVerifiedBytes: r.KeepsVerifiedBytes,
		ImageRef:          r.ImageRef,
	}
	if r.DiscardsRootDisk {
		if err := os.Remove(filepath.Join(dir, "disks", "root.disk")); err != nil && !os.IsNotExist(err) {
			return p, fmt.Errorf("removing the unfinished root.disk: %w", err)
		}
		p.DiscardedRootDisk = true
	}
	return p, nil
}

// GetInstallRecovery classifies the last install attempt for the relaunch
// screen.
func (a *App) GetInstallRecovery() InstallRecovery {
	a.mu.Lock()
	running := a.status.Running
	a.mu.Unlock()
	if running {
		return InstallRecovery{Class: InstallClassInProgress}
	}
	return inspectInstallRecovery()
}

// PrepareResume discards an unfinished attempt's own root.disk (keeping the
// verified download) so the launchpad can start the install again.
func (a *App) PrepareResume() (ResumePreparation, error) {
	a.mu.Lock()
	running := a.status.Running
	a.mu.Unlock()
	if running {
		return ResumePreparation{}, fmt.Errorf("an install is running")
	}
	return prepareResumeAt(wootcDir(), processAlive)
}
