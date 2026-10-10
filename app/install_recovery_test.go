package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testBlobDigest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func testJournal(outcome, current string, done ...string) *InstallJournal {
	if done == nil {
		done = []string{}
	}
	return &InstallJournal{
		Schema: 1, AttemptID: "t", ImageRef: "ghcr.io/tuna-os/yellowfin:gnome",
		PID: 4242, StartedAt: "2026-10-01T10:00:00Z", Outcome: outcome,
		CurrentStep: current, CompletedSteps: done,
	}
}

// stepsThrough returns the installer steps up to and including last, in
// pipeline order, the way a journal records them.
func stepsThrough(last string) []string {
	order := []string{
		StepInstallerCheckingYourPC, StepInstallerPreparingWindows, StepInstallerSettingThingsUp,
		StepInstallerFindingYourFiles, StepInstallerMakingRoomForLinux, StepInstallerDownloadingLinux,
		StepInstallerDownloadingYourLinuxSystem, StepInstallerPreparingTheStartupMenu,
		StepInstallerGettingLinuxPrepared, StepInstallerMakingLinuxBootableOnYourMachine,
	}
	for i, s := range order {
		if s == last {
			return append([]string{}, order[:i+1]...)
		}
	}
	panic("unknown step " + last)
}

func TestClassifyInstall(t *testing.T) {
	afterRoot := "2026-10-01T10:00:30Z"
	tests := []struct {
		name        string
		obs         InstallObservation
		class       string
		cause       string
		actions     InstallRecoveryActions
		recommended string
		discards    bool
		stoppedAt   string
		last        string
	}{
		{
			name:  "nothing on record",
			obs:   InstallObservation{},
			class: InstallClassNone,
		},
		{
			name: "power lost during the image pull resumes the verified download",
			obs: InstallObservation{
				Journal:         testJournal(JournalRunning, StepInstallerDownloadingYourLinuxSystem, stepsThrough(StepInstallerDownloadingLinux)...),
				State:           &LifecycleState{State: StateStaged},
				Bundle:          BundleEvidence{VerifiedBlobs: 3, VerifiedBytes: 3e9, PartialFiles: 1},
				RootDisk:        true,
				RootDiskModTime: afterRoot,
			},
			class: InstallClassResumable, cause: CauseInterrupted,
			actions:     InstallRecoveryActions{ResumeInstall: true, Remove: true},
			recommended: "resume", discards: true,
			stoppedAt: StepInstallerDownloadingYourLinuxSystem, last: StepInstallerDownloadingLinux,
		},
		{
			name: "a live owner process means the install is still running",
			obs: InstallObservation{
				Journal:        testJournal(JournalRunning, StepInstallerDownloadingYourLinuxSystem),
				JournalOwnerUp: true,
			},
			class:     InstallClassInProgress,
			stoppedAt: StepInstallerDownloadingYourLinuxSystem,
		},
		{
			name: "deliberate cancel is told apart from an interruption",
			obs: InstallObservation{
				Journal: testJournal(JournalCancelled, StepInstallerDownloadingYourLinuxSystem, stepsThrough(StepInstallerDownloadingLinux)...),
			},
			class: InstallClassResumable, cause: CauseCancelled,
			actions:     InstallRecoveryActions{ResumeInstall: true, Remove: true},
			recommended: "resume",
			stoppedAt:   StepInstallerDownloadingYourLinuxSystem, last: StepInstallerDownloadingLinux,
		},
		{
			name: "a failed step is failed, not resumable",
			obs: InstallObservation{
				Journal: testJournal(JournalFailed, StepInstallerDownloadingYourLinuxSystem, stepsThrough(StepInstallerDownloadingLinux)...),
			},
			class: InstallClassFailed, cause: CauseStepFailed,
			actions:     InstallRecoveryActions{ResumeInstall: true, Remove: true},
			recommended: "resume",
			stoppedAt:   StepInstallerDownloadingYourLinuxSystem, last: StepInstallerDownloadingLinux,
		},
		{
			name: "root.disk older than the attempt is never discarded",
			obs: InstallObservation{
				Journal:         testJournal(JournalRunning, StepInstallerDownloadingYourLinuxSystem, stepsThrough(StepInstallerDownloadingLinux)...),
				RootDisk:        true,
				RootDiskModTime: "2026-09-01T10:00:00Z",
			},
			class: InstallClassResumable, cause: CauseInterrupted,
			actions:     InstallRecoveryActions{Remove: true},
			recommended: "remove",
			stoppedAt:   StepInstallerDownloadingYourLinuxSystem, last: StepInstallerDownloadingLinux,
		},
		{
			name: "root.disk the attempt never reached is never discarded",
			obs: InstallObservation{
				Journal:         testJournal(JournalRunning, StepInstallerFindingYourFiles, stepsThrough(StepInstallerSettingThingsUp)...),
				RootDisk:        true,
				RootDiskModTime: afterRoot,
			},
			class: InstallClassResumable, cause: CauseInterrupted,
			actions:     InstallRecoveryActions{Remove: true},
			recommended: "remove",
			stoppedAt:   StepInstallerFindingYourFiles, last: StepInstallerSettingThingsUp,
		},
		{
			name: "interrupted while staging the ESP needs repair",
			obs: InstallObservation{
				Journal:         testJournal(JournalRunning, StepInstallerGettingLinuxPrepared, stepsThrough(StepInstallerPreparingTheStartupMenu)...),
				RootDisk:        true,
				RootDiskModTime: afterRoot,
			},
			class: InstallClassNeedsRepair, cause: CauseInterrupted,
			actions:     InstallRecoveryActions{Remove: true},
			recommended: "remove",
			stoppedAt:   StepInstallerGettingLinuxPrepared, last: StepInstallerPreparingTheStartupMenu,
		},
		{
			name: "interrupted after arming offers the recorded repair",
			obs: InstallObservation{
				Journal:   testJournal(JournalRunning, StepInstallerSavingYourSettings, stepsThrough(StepInstallerMakingLinuxBootableOnYourMachine)...),
				ArmedFile: true,
			},
			class: InstallClassNeedsRepair, cause: CauseInterrupted,
			actions:     InstallRecoveryActions{Remove: true, RepairBoot: true},
			recommended: "remove",
			stoppedAt:   StepInstallerSavingYourSettings, last: StepInstallerMakingLinuxBootableOnYourMachine,
		},
		{
			name: "cancel after the boot step still needs cleanup before a new run",
			obs: InstallObservation{
				Journal:   testJournal(JournalCancelled, StepInstallerSavingYourSettings, stepsThrough(StepInstallerMakingLinuxBootableOnYourMachine)...),
				ArmedFile: true,
			},
			class: InstallClassNeedsRepair, cause: CauseCancelled,
			actions:     InstallRecoveryActions{Remove: true, RepairBoot: true},
			recommended: "remove",
			stoppedAt:   StepInstallerSavingYourSettings, last: StepInstallerMakingLinuxBootableOnYourMachine,
		},
		{
			name: "armed before the restart is complete",
			obs: InstallObservation{
				Journal:   testJournal(JournalArmed, "", stepsThrough(StepInstallerMakingLinuxBootableOnYourMachine)...),
				State:     &LifecycleState{State: StateArmed},
				ArmedFile: true,
			},
			class: InstallClassComplete, cause: CauseAwaitingRestart,
			actions: InstallRecoveryActions{Remove: true},
			last:    StepInstallerMakingLinuxBootableOnYourMachine,
		},
		{
			name: "armed but Windows came back without the deployer",
			obs: InstallObservation{
				Journal:     testJournal(JournalArmed, "", stepsThrough(StepInstallerMakingLinuxBootableOnYourMachine)...),
				State:       &LifecycleState{State: StateArmed},
				ArmedFile:   true,
				VerdictFile: true,
			},
			class: InstallClassResumable, cause: CauseNeverBooted,
			actions:     InstallRecoveryActions{RetryDeploy: true, RepairBoot: true, Remove: true},
			recommended: "retry-deploy",
			last:        StepInstallerMakingLinuxBootableOnYourMachine,
		},
		{
			name: "deployer interrupted mid-install retries the deploy",
			obs: InstallObservation{
				Journal:         testJournal(JournalArmed, "", stepsThrough(StepInstallerMakingLinuxBootableOnYourMachine)...),
				State:           &LifecycleState{State: StateDeploying, PhaseID: StepDeployerFisherman},
				ArmedFile:       true,
				DeployerStarted: true,
			},
			class: InstallClassResumable, cause: CauseDeployerInterrupted,
			actions:     InstallRecoveryActions{RetryDeploy: true, RepairBoot: true, Remove: true},
			recommended: "retry-deploy",
			stoppedAt:   StepDeployerFisherman, last: StepInstallerMakingLinuxBootableOnYourMachine,
		},
		{
			name: "deployer failure without armed.json only offers removal",
			obs: InstallObservation{
				State:           &LifecycleState{State: StateFailed, PhaseID: StepDeployerFisherman, Error: "pull failed"},
				DeployerStarted: true,
			},
			class: InstallClassFailed, cause: CauseDeployerFailed,
			actions:     InstallRecoveryActions{Remove: true},
			recommended: "remove",
			stoppedAt:   StepDeployerFisherman,
		},
		{
			name:  "healthy Phase 2 is complete with nothing to do",
			obs:   InstallObservation{State: &LifecycleState{State: StateHealthy}, ArmedFile: true, DeployerStarted: true},
			class: InstallClassComplete, cause: CauseHealthy,
		},
		{
			name:  "deployed is complete and removable",
			obs:   InstallObservation{State: &LifecycleState{State: StateDeployed}, DeployerStarted: true},
			class: InstallClassComplete, cause: CauseDeployed,
			actions: InstallRecoveryActions{Remove: true},
		},
		{
			name: "an unknown journal outcome is never resumed",
			obs: InstallObservation{
				Journal: testJournal("exploded", StepInstallerDownloadingLinux),
			},
			class: InstallClassNeedsRepair, cause: CauseUnknown,
			actions:     InstallRecoveryActions{Remove: true},
			recommended: "remove",
			stoppedAt:   StepInstallerDownloadingLinux,
		},
		{
			name: "pre-journal staged record cannot tell a crash from a run",
			obs: InstallObservation{
				State:    &LifecycleState{State: StateStaged},
				RootDisk: true,
			},
			class: InstallClassFailed, cause: CauseUnknown,
			actions:     InstallRecoveryActions{Remove: true},
			recommended: "remove",
		},
		{
			name: "pre-journal cancel with no root.disk can start again",
			obs: InstallObservation{
				State: &LifecycleState{State: StateStaged, Phase: "cancelled"},
			},
			class: InstallClassResumable, cause: CauseCancelled,
			actions:     InstallRecoveryActions{ResumeInstall: true, Remove: true},
			recommended: "resume",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r := classifyInstall(tc.obs)
			if r.Class != tc.class || r.Cause != tc.cause {
				t.Fatalf("class/cause = %s/%s, want %s/%s", r.Class, r.Cause, tc.class, tc.cause)
			}
			if r.Actions != tc.actions {
				t.Errorf("actions = %+v, want %+v", r.Actions, tc.actions)
			}
			if r.Recommended != tc.recommended {
				t.Errorf("recommended = %q, want %q", r.Recommended, tc.recommended)
			}
			if r.DiscardsRootDisk != tc.discards {
				t.Errorf("discardsRootDisk = %v, want %v", r.DiscardsRootDisk, tc.discards)
			}
			if r.StoppedAtStep != tc.stoppedAt {
				t.Errorf("stoppedAt = %q, want %q", r.StoppedAtStep, tc.stoppedAt)
			}
			if r.LastCompletedStep != tc.last {
				t.Errorf("lastCompleted = %q, want %q", r.LastCompletedStep, tc.last)
			}
			if r.Class != InstallClassNone && r.Class != InstallClassInProgress && r.Title == "" {
				t.Error("a classified attempt must explain itself with a title")
			}
			if len(r.Evidence) == 0 {
				t.Error("evidence must never be empty")
			}
		})
	}
}

// The repair and retry buttons must never appear for an attempt whose boot
// chain wootc has no record of: they act on armed.json.
func TestClassifyInstallBootActionsRequireArmedRecord(t *testing.T) {
	for _, state := range []string{StateDeploying, StateFailed} {
		r := classifyInstall(InstallObservation{
			State:           &LifecycleState{State: state},
			DeployerStarted: true,
		})
		if r.Actions.RetryDeploy || r.Actions.RepairBoot {
			t.Errorf("%s without armed.json offered %+v", state, r.Actions)
		}
		if !r.Actions.Remove {
			t.Errorf("%s must still offer removal", state)
		}
	}
}

func writeTestFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestObserveInstallAtReadsEveryInput(t *testing.T) {
	dir := t.TempDir()
	rec := newInstallJournalRecorder(filepath.Join(dir, "install", "journal.json"), InstallConfig{ImageRef: "img"}, nil)
	rec.stepStarted(StepInstallerDownloadingYourLinuxSystem)
	writeTestFile(t, filepath.Join(dir, "state.json"), `{"state":"staged"}`)
	writeTestFile(t, filepath.Join(dir, "install", "armed.json"), `{}`)
	blobs := filepath.Join(dir, "bundle", "oci", "blobs", "sha256")
	writeTestFile(t, filepath.Join(blobs, testBlobDigest), "12345")
	writeTestFile(t, filepath.Join(blobs, strings.Repeat("f", 64)+".part"), "12")
	writeTestFile(t, filepath.Join(blobs, "not-a-digest"), "123")
	writeTestFile(t, filepath.Join(dir, "disks", "root.disk"), "")

	var asked int
	o := observeInstallAt(dir, func(pid int) bool { asked = pid; return false })
	if o.Journal == nil || o.Journal.Outcome != JournalRunning || o.Journal.CurrentStep != StepInstallerDownloadingYourLinuxSystem {
		t.Fatalf("journal = %+v", o.Journal)
	}
	if asked != os.Getpid() {
		t.Errorf("liveness asked about pid %d, want the journal's %d", asked, os.Getpid())
	}
	if o.State == nil || o.State.State != StateStaged || !o.ArmedFile || o.DeployerStarted || o.VerdictFile {
		t.Errorf("markers = %+v", o)
	}
	if o.Bundle.VerifiedBlobs != 1 || o.Bundle.VerifiedBytes != 5 || o.Bundle.PartialFiles != 1 || o.Bundle.Complete {
		t.Errorf("bundle = %+v", o.Bundle)
	}
	if !o.RootDisk || o.RootDiskModTime == "" {
		t.Errorf("root.disk not observed: %+v", o)
	}
}

func TestObserveInstallAtReportsUnreadableJournal(t *testing.T) {
	dir := t.TempDir()
	writeTestFile(t, filepath.Join(dir, "install", "journal.json"), "{not json")
	o := observeInstallAt(dir, nil)
	if o.Journal != nil || o.JournalError == "" {
		t.Fatalf("a corrupt journal must be reported, got %+v", o)
	}
	r := classifyInstall(o)
	if !strings.Contains(strings.Join(r.Evidence, "\n"), "journal.json unreadable") {
		t.Errorf("evidence hides the corrupt journal: %v", r.Evidence)
	}
}

func TestInstallJournalRecorderLifecycle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "install", "journal.json")
	clock := time.Date(2026, 10, 1, 10, 0, 0, 0, time.UTC)
	rec := newInstallJournalRecorder(path, InstallConfig{ImageRef: "img", StorageDrive: "D", Password: "secret", LuksPassphrase: "hunter2"}, func() time.Time { return clock })

	read := func() InstallJournal {
		t.Helper()
		j, ok, err := readJournalAt(path)
		if err != nil || !ok {
			t.Fatalf("journal unreadable: ok=%v err=%v", ok, err)
		}
		return j
	}
	if j := read(); j.Outcome != JournalRunning || j.ImageRef != "img" || j.StorageDrive != "D" || j.PID != os.Getpid() {
		t.Fatalf("begin = %+v", j)
	}
	rec.stepStarted(StepInstallerCheckingYourPC)
	if j := read(); j.CurrentStep != StepInstallerCheckingYourPC || len(j.CompletedSteps) != 0 {
		t.Fatalf("after start = %+v", j)
	}
	rec.stepDone(StepInstallerCheckingYourPC)
	rec.stepStarted(StepInstallerPreparingWindows)
	rec.end(JournalFailed, "boom")
	j := read()
	if j.Outcome != JournalFailed || j.Error != "boom" || j.EndedAt == "" {
		t.Fatalf("end = %+v", j)
	}
	if j.CurrentStep != StepInstallerPreparingWindows || j.LastCompletedStep() != StepInstallerCheckingYourPC {
		t.Fatalf("failed step lost: %+v", j)
	}
	data, _ := os.ReadFile(path)
	if strings.Contains(string(data), "secret") || strings.Contains(string(data), "hunter2") {
		t.Fatal("the journal must never record a password or passphrase")
	}
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("temporary journal left behind: %v", err)
	}
}

func TestPrepareResumeDiscardsOnlyTheAttemptsOwnRootDisk(t *testing.T) {
	dir := t.TempDir()
	rec := newInstallJournalRecorder(filepath.Join(dir, "install", "journal.json"), InstallConfig{ImageRef: "img"}, nil)
	for _, s := range stepsThrough(StepInstallerDownloadingLinux) {
		rec.stepStarted(s)
		rec.stepDone(s)
	}
	rec.stepStarted(StepInstallerDownloadingYourLinuxSystem)
	blob := filepath.Join(dir, "bundle", "oci", "blobs", "sha256", testBlobDigest)
	writeTestFile(t, blob, "verified")
	root := filepath.Join(dir, "disks", "root.disk")
	writeTestFile(t, root, "")

	dead := func(int) bool { return false }
	p, err := prepareResumeAt(dir, dead)
	if err != nil {
		t.Fatal(err)
	}
	if !p.DiscardedRootDisk || p.KeptVerifiedBlobs != 1 || p.ImageRef != "img" {
		t.Fatalf("prepare = %+v", p)
	}
	if _, err := os.Stat(root); !os.IsNotExist(err) {
		t.Fatal("the attempt's own root.disk must be removed so a new install can start")
	}
	if _, err := os.Stat(blob); err != nil {
		t.Fatal("verified download pieces must be kept for the resume")
	}
}

func TestPrepareResumeRefusesWhenUnsafe(t *testing.T) {
	dead := func(int) bool { return false }
	cases := map[string]func(t *testing.T, dir string){
		"root.disk predates the attempt": func(t *testing.T, dir string) {
			rec := newInstallJournalRecorder(filepath.Join(dir, "install", "journal.json"), InstallConfig{}, nil)
			rec.stepStarted(StepInstallerMakingRoomForLinux)
			root := filepath.Join(dir, "disks", "root.disk")
			writeTestFile(t, root, "linux data")
			old := time.Now().Add(-48 * time.Hour)
			if err := os.Chtimes(root, old, old); err != nil {
				t.Fatal(err)
			}
		},
		"boot chain touched": func(t *testing.T, dir string) {
			rec := newInstallJournalRecorder(filepath.Join(dir, "install", "journal.json"), InstallConfig{}, nil)
			rec.stepStarted(StepInstallerGettingLinuxPrepared)
			writeTestFile(t, filepath.Join(dir, "disks", "root.disk"), "")
		},
		"deployer started": func(t *testing.T, dir string) {
			rec := newInstallJournalRecorder(filepath.Join(dir, "install", "journal.json"), InstallConfig{}, nil)
			rec.stepStarted(StepInstallerMakingRoomForLinux)
			rec.end(JournalCancelled, "")
			writeTestFile(t, filepath.Join(dir, "install", "deployer-started.json"), "{}")
			writeTestFile(t, filepath.Join(dir, "disks", "root.disk"), "")
		},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			setup(t, dir)
			before := pathExists(filepath.Join(dir, "disks", "root.disk"))
			if _, err := prepareResumeAt(dir, dead); err == nil {
				t.Fatal("resume must be refused")
			}
			if before && !pathExists(filepath.Join(dir, "disks", "root.disk")) {
				t.Fatal("a refused resume deleted root.disk")
			}
		})
	}
}

// A cancel observed at a step boundary must reach the journal as a cancel,
// not leave "running" behind for the next launch to call a crash.
func TestRunPipelineJournalsCancellation(t *testing.T) {
	path := journalPath()
	if prev, err := os.ReadFile(path); err == nil {
		t.Cleanup(func() { _ = os.WriteFile(path, prev, 0o600) })
	} else {
		t.Cleanup(func() { _ = os.Remove(path) })
	}
	statePrev, stateErr := os.ReadFile(statePath())
	t.Cleanup(func() {
		if stateErr == nil {
			_ = os.WriteFile(statePath(), statePrev, 0o600)
		} else {
			_ = os.Remove(statePath())
		}
	})

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := runPipeline(ctx, InstallConfig{ImageRef: "img"}, func(ProgressEvent) {}); err != context.Canceled {
		t.Fatalf("runPipeline = %v, want context.Canceled", err)
	}
	j, ok, err := readJournalAt(path)
	if err != nil || !ok {
		t.Fatalf("journal missing: ok=%v err=%v", ok, err)
	}
	if j.Outcome != JournalCancelled || j.ImageRef != "img" {
		t.Fatalf("journal = %+v", j)
	}
}
