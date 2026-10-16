package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// InstallRecoverySummary is the stdio projection of InstallRecovery (#287).
// It carries the classification, the safe actions and the fixed engine copy,
// and leaves out the evidence lines, the step error and the raw observation:
// those can hold paths and free-form error text, which the native pipe does
// not carry. Step IDs are present only when they are known catalogue IDs.
type InstallRecoverySummary struct {
	Class              string                 `json:"class"`
	Cause              string                 `json:"cause"`
	ImageRef           string                 `json:"imageRef"`
	LastCompletedStep  string                 `json:"lastCompletedStep"`
	StoppedAtStep      string                 `json:"stoppedAtStep"`
	Title              string                 `json:"title"`
	Message            string                 `json:"message"`
	Recommended        string                 `json:"recommended"`
	Actions            InstallRecoveryActions `json:"actions"`
	DiscardsRootDisk   bool                   `json:"discardsRootDisk"`
	KeepsVerifiedBlobs int                    `json:"keepsVerifiedBlobs"`
	KeepsVerifiedBytes int64                  `json:"keepsVerifiedBytes"`
}

func summarizeInstallRecovery(r InstallRecovery) InstallRecoverySummary {
	s := InstallRecoverySummary{
		Class: r.Class, Cause: r.Cause, ImageRef: r.ImageRef,
		LastCompletedStep: observedStepID(r.LastCompletedStep), StoppedAtStep: observedStepID(r.StoppedAtStep),
		Title: r.Title, Message: r.Message, Recommended: r.Recommended, Actions: r.Actions,
		DiscardsRootDisk: r.DiscardsRootDisk, KeepsVerifiedBlobs: r.KeepsVerifiedBlobs, KeepsVerifiedBytes: r.KeepsVerifiedBytes,
	}
	if s.Class == "" {
		s.Class = InstallClassNone
	}
	return s
}

// readNativeInstallRecovery classifies the attempt under an audited state
// root with strict, bounded reads only. It never repairs, creates or removes
// anything; an ambiguous or malformed record is a refusal, not a guess.
func readNativeInstallRecovery(root string, running func(InstallJournal) bool) (InstallRecoverySummary, error) {
	observation, err := observeNativeInstallAt(root, running)
	if err != nil {
		return InstallRecoverySummary{}, err
	}
	return summarizeInstallRecovery(classifyInstall(observation)), nil
}

func observeNativeInstallAt(root string, running func(InstallJournal) bool) (InstallObservation, error) {
	var o InstallObservation
	install := filepath.Join(root, "install")
	journal, found, err := readNativeInstallJournal(filepath.Join(install, "journal.json"))
	if err != nil {
		return o, err
	}
	if found {
		o.Journal = &journal
		if journal.Outcome == JournalRunning && journal.PID > 0 && running != nil {
			o.JournalOwnerUp = running(journal)
		}
	}
	state, err := readNativeStartupLifecycle(root)
	if err != nil {
		return o, err
	}
	if state.State != "" {
		o.State = &state
	}
	for _, marker := range []struct {
		name    string
		present *bool
	}{{"armed.json", &o.ArmedFile}, {"deployer-started.json", &o.DeployerStarted}, {"recovery-verdict.json", &o.VerdictFile}} {
		if *marker.present, _, err = nativeRegularFile(filepath.Join(install, marker.name)); err != nil {
			return o, err
		}
	}
	if o.Bundle, err = countNativeVerifiedBlobs(filepath.Join(root, "bundle", "oci", "blobs", "sha256")); err != nil {
		return o, err
	}
	present, info, err := nativeRegularFile(filepath.Join(root, "disks", "root.disk"))
	if err != nil {
		return o, err
	}
	if present {
		o.RootDisk = true
		o.RootDiskModTime = info.ModTime().UTC().Format(time.RFC3339)
	}
	return o, nil
}

// nativeRegularFile reports a marker without following links; anything other
// than an absent path or a regular file is refused.
func nativeRegularFile(path string) (bool, os.FileInfo, error) {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return false, nil, nil
	}
	if err != nil {
		return false, nil, err
	}
	if !info.Mode().IsRegular() {
		return false, nil, fmt.Errorf("install recovery marker is not a regular file")
	}
	return true, info, nil
}

// countNativeVerifiedBlobs counts digest-named blobs, which are renamed into
// place only after verification. It does not read bundle.json: the summary
// needs only the pieces a resume keeps.
func countNativeVerifiedBlobs(dir string) (BundleEvidence, error) {
	var evidence BundleEvidence
	entries, err := os.ReadDir(dir)
	if os.IsNotExist(err) {
		return evidence, nil
	}
	if err != nil {
		return evidence, err
	}
	for _, entry := range entries {
		name := entry.Name()
		if strings.HasSuffix(name, ".part") {
			evidence.PartialFiles++
			continue
		}
		if len(name) != 64 || strings.Trim(name, "0123456789abcdef") != "" {
			continue
		}
		info, err := os.Lstat(filepath.Join(dir, name))
		if err != nil {
			return evidence, err
		}
		if !info.Mode().IsRegular() {
			return evidence, fmt.Errorf("verified blob is not a regular file")
		}
		evidence.VerifiedBlobs++
		evidence.VerifiedBytes += info.Size()
	}
	return evidence, nil
}

// readNativeInstallJournal is the strict counterpart of readJournalAt: bounded,
// no duplicate, unknown or null fields, a known outcome and catalogue step IDs.
func readNativeInstallJournal(path string) (InstallJournal, bool, error) {
	data, err := readBoundedStatusRecord(path)
	if os.IsNotExist(err) {
		return InstallJournal{}, false, nil
	}
	if err != nil {
		return InstallJournal{}, false, err
	}
	var journal InstallJournal
	fields := map[string]string{"schema": "int", "attemptId": "string", "imageRef": "string", "storageDrive": "string", "pid": "int", "startedAt": "string", "updatedAt": "string", "endedAt": "string", "outcome": "string", "currentStep": "string", "completedSteps": "strings", "error": "string"}
	if err := decodeStrictStatusRecord(data, &journal, fields, []string{"schema", "attemptId", "pid", "startedAt", "updatedAt", "outcome", "completedSteps"}); err != nil {
		return InstallJournal{}, false, err
	}
	if journal.Schema != 1 || journal.PID < 0 || strings.TrimSpace(journal.AttemptID) == "" || len(journal.ImageRef) > 512 || strings.ContainsAny(journal.ImageRef, "\r\n\t") {
		return InstallJournal{}, false, fmt.Errorf("unsupported install journal")
	}
	switch journal.Outcome {
	case JournalRunning, JournalCancelled, JournalFailed, JournalArmed:
	default:
		return InstallJournal{}, false, fmt.Errorf("unsupported install journal outcome")
	}
	for _, stamp := range []string{journal.StartedAt, journal.UpdatedAt} {
		if _, err := time.Parse(time.RFC3339, stamp); err != nil {
			return InstallJournal{}, false, fmt.Errorf("invalid install journal time")
		}
	}
	if len(journal.CompletedSteps) > 64 || (journal.CurrentStep != "" && observedStepID(journal.CurrentStep) == "") {
		return InstallJournal{}, false, fmt.Errorf("unsupported install journal step")
	}
	for _, step := range journal.CompletedSteps {
		if observedStepID(step) == "" {
			return InstallJournal{}, false, fmt.Errorf("unsupported install journal step")
		}
	}
	return journal, true, nil
}

// journalOwnerSlack covers the journal's one-second timestamps and the time
// between process start and the first journal write.
const journalOwnerSlack = 2 * time.Minute

// journalOwnerRunning reports whether the journal's PID is a live process that
// was created before the journal started. The native engine has a different
// executable name from the legacy installer, so the name check in
// processAlive cannot identify the owner; the creation time can, and a PID
// that Windows reused after a reboot was created later and never passes.
func journalOwnerRunning(journal InstallJournal) bool {
	started, err := time.Parse(time.RFC3339, journal.StartedAt)
	if err != nil {
		return false
	}
	created, ok := processCreationTime(journal.PID)
	return ok && !created.After(started.Add(journalOwnerSlack))
}
