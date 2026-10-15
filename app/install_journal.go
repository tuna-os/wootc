package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// ── Install journal (#287) ───────────────────────────────────────────────────
// state.json answers "what state is the lifecycle in"; it does not say how the
// last attempt ended or which steps finished. A process killed by a power cut
// leaves state.json exactly as the previous step wrote it, and nothing
// distinguishes that from a deliberate cancel. The journal is the durable
// record that does: every step start and finish is written before the
// pipeline moves on, and only a clean exit writes an outcome. An outcome of
// "running" that no live process owns is therefore positive evidence of an
// unexpected interruption, not a guess from a single folder or marker.
//
// C:\wootc\install\journal.json — removed by uninstall with the install dir.

const (
	JournalRunning   = "running"   // set at start; only a clean exit replaces it
	JournalCancelled = "cancelled" // the user (or engine shutdown) cancelled
	JournalFailed    = "failed"    // a step returned an error
	JournalArmed     = "armed"     // Phase 1 finished; reboot into the deployer pending
)

// InstallJournal is the persisted contents of journal.json. It holds no
// secrets: passwords and LUKS passphrases are never recorded, so a resume
// always goes back through the launchpad to ask for them again.
type InstallJournal struct {
	Schema         int      `json:"schema"`
	AttemptID      string   `json:"attemptId"`
	ImageRef       string   `json:"imageRef,omitempty"`
	StorageDrive   string   `json:"storageDrive,omitempty"`
	PID            int      `json:"pid"`
	StartedAt      string   `json:"startedAt"`
	UpdatedAt      string   `json:"updatedAt"`
	EndedAt        string   `json:"endedAt,omitempty"`
	Outcome        string   `json:"outcome"`
	CurrentStep    string   `json:"currentStep,omitempty"` // started, not yet finished
	CompletedSteps []string `json:"completedSteps"`
	Error          string   `json:"error,omitempty"`
}

// LastCompletedStep is the newest step that finished, or "" before any did.
func (j InstallJournal) LastCompletedStep() string {
	if len(j.CompletedSteps) == 0 {
		return ""
	}
	return j.CompletedSteps[len(j.CompletedSteps)-1]
}

// Completed reports whether step finished in this attempt.
func (j InstallJournal) Completed(step string) bool {
	for _, s := range j.CompletedSteps {
		if s == step {
			return true
		}
	}
	return false
}

func journalPath() string {
	return filepath.Join(wootcDir(), "install", "journal.json")
}

// writeJournalAt persists j through a temporary file and a rename, so a power
// cut mid-write leaves the previous journal rather than a truncated one.
func writeJournalAt(path string, j InstallJournal) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("creating install dir: %w", err)
	}
	data, err := json.MarshalIndent(j, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

// readJournalAt loads a journal. ok is false when it is absent; err is set
// when it exists but cannot be parsed, which recovery reports as evidence.
func readJournalAt(path string) (InstallJournal, bool, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return InstallJournal{}, false, nil
	}
	if err != nil {
		return InstallJournal{}, false, err
	}
	var j InstallJournal
	if err := json.Unmarshal(data, &j); err != nil {
		return InstallJournal{}, false, fmt.Errorf("parsing journal.json: %w", err)
	}
	return j, true, nil
}

// installJournalRecorder writes the journal as the pipeline runs. Writes are
// best-effort like writeState: a journal failure must never abort an install,
// but it is reported on stderr so a missing record is never silent.
type installJournalRecorder struct {
	path string
	j    InstallJournal
	now  func() time.Time
}

func newInstallJournalRecorder(path string, cfg InstallConfig, now func() time.Time) *installJournalRecorder {
	if now == nil {
		now = time.Now
	}
	t := now().UTC()
	r := &installJournalRecorder{path: path, now: now, j: InstallJournal{
		Schema:         1,
		AttemptID:      t.Format("20060102T150405.000000000Z"),
		ImageRef:       cfg.ImageRef,
		StorageDrive:   cfg.StorageDrive,
		PID:            os.Getpid(),
		StartedAt:      t.Format(time.RFC3339),
		Outcome:        JournalRunning,
		CompletedSteps: []string{},
	}}
	r.flush()
	return r
}

func (r *installJournalRecorder) flush() {
	if r == nil {
		return
	}
	r.j.UpdatedAt = r.now().UTC().Format(time.RFC3339)
	if err := writeJournalAt(r.path, r.j); err != nil {
		fmt.Fprintf(os.Stderr, "[wootc] warning: install journal not written: %v\n", err)
	}
}

func (r *installJournalRecorder) stepStarted(step string) {
	if r == nil {
		return
	}
	r.j.CurrentStep = step
	r.flush()
}

func (r *installJournalRecorder) stepDone(step string) {
	if r == nil {
		return
	}
	r.j.CompletedSteps = append(r.j.CompletedSteps, step)
	r.j.CurrentStep = ""
	r.flush()
}

// end records how the attempt finished. For a failure or cancel, CurrentStep
// keeps the step that was running so recovery can name it.
func (r *installJournalRecorder) end(outcome, errMsg string) {
	if r == nil {
		return
	}
	r.j.Outcome = outcome
	r.j.Error = errMsg
	r.j.EndedAt = r.now().UTC().Format(time.RFC3339)
	r.flush()
}
