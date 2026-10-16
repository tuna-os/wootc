package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

const statusFixtureStaged = `{"state":"staged","phase":"Downloading Linux","phaseId":"Downloading Linux","updatedAt":"2026-10-15T10:00:00Z","updatedBy":"wootc"}`

func statusJournalFixture(outcome, current, failure string) string {
	value := map[string]any{"schema": 1, "attemptId": "20261015T100000.000000000Z", "imageRef": "ghcr.io/tuna-os/yellowfin:gnome", "storageDrive": "C", "pid": 4242,
		"startedAt": "2026-10-15T10:00:00Z", "updatedAt": "2026-10-15T10:05:00Z", "outcome": outcome,
		"completedSteps": []string{StepInstallerCheckingYourPC, StepInstallerPreparingWindows}}
	if current != "" {
		value["currentStep"] = current
	}
	if failure != "" {
		value["error"] = failure
		value["endedAt"] = "2026-10-15T10:06:00Z"
	}
	data, _ := json.Marshal(value)
	return string(data)
}

func writeStatusRecoveryRoot(t *testing.T, root, journal, state string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, "install"), 0700); err != nil {
		t.Fatal(err)
	}
	if journal != "" {
		if err := os.WriteFile(filepath.Join(root, "install", "journal.json"), []byte(journal), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if state != "" {
		if err := os.WriteFile(filepath.Join(root, "state.json"), []byte(state), 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func notRunning(InstallJournal) bool { return false }

func TestStatusInstallRecoveryAbsentRootIsNone(t *testing.T) {
	summary, err := readNativeInstallRecovery(filepath.Join(t.TempDir(), "wootc"), notRunning)
	if err != nil || summary.Class != InstallClassNone || summary.Title != "" || summary.Actions != (InstallRecoveryActions{}) {
		t.Fatalf("absent root: %+v %v", summary, err)
	}
}

func TestStatusInstallRecoveryInterruptedMatchesRelaunchClassifier(t *testing.T) {
	cases := map[string]struct {
		journal, class, cause string
	}{
		"interrupted": {statusJournalFixture(JournalRunning, StepInstallerDownloadingLinux, ""), InstallClassResumable, CauseInterrupted},
		"cancelled":   {statusJournalFixture(JournalCancelled, StepInstallerDownloadingLinux, ""), InstallClassResumable, CauseCancelled},
		"failed":      {statusJournalFixture(JournalFailed, StepInstallerDownloadingLinux, `copy failed at C:\Users\private\secret.txt`), InstallClassFailed, CauseStepFailed},
		"boot-chain":  {statusJournalFixture(JournalRunning, StepInstallerGettingLinuxPrepared, ""), InstallClassNeedsRepair, CauseInterrupted},
	}
	for name, test := range cases {
		t.Run(name, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "wootc")
			writeStatusRecoveryRoot(t, root, test.journal, statusFixtureStaged)
			summary, err := readNativeInstallRecovery(root, notRunning)
			if err != nil {
				t.Fatal(err)
			}
			if summary.Class != test.class || summary.Cause != test.cause || summary.Title == "" || summary.Message == "" {
				t.Fatalf("summary %+v", summary)
			}
			// The strict native reader and the Wails relaunch classifier agree.
			legacy := summarizeInstallRecovery(classifyInstall(observeInstallAt(root, func(int) bool { return false })))
			if !reflect.DeepEqual(summary, legacy) {
				t.Fatalf("native %+v differs from relaunch %+v", summary, legacy)
			}
			data, _ := json.Marshal(summary)
			if bytes.Contains(data, []byte("secret")) || bytes.Contains(data, []byte(`private`)) {
				t.Fatalf("summary carries step error text: %s", data)
			}
			var fields map[string]json.RawMessage
			if err := json.Unmarshal(data, &fields); err != nil {
				t.Fatal(err)
			}
			keys := make([]string, 0, len(fields))
			for key := range fields {
				keys = append(keys, key)
			}
			sort.Strings(keys)
			want := []string{"actions", "cause", "class", "discardsRootDisk", "imageRef", "keepsVerifiedBlobs", "keepsVerifiedBytes", "lastCompletedStep", "message", "recommended", "stoppedAtStep", "title"}
			if !reflect.DeepEqual(keys, want) {
				t.Fatalf("summary fields %v", keys)
			}
		})
	}
}

func TestStatusInstallRecoveryLiveOwnerIsInProgress(t *testing.T) {
	root := filepath.Join(t.TempDir(), "wootc")
	writeStatusRecoveryRoot(t, root, statusJournalFixture(JournalRunning, StepInstallerDownloadingLinux, ""), statusFixtureStaged)
	summary, err := readNativeInstallRecovery(root, func(InstallJournal) bool { return true })
	if err != nil || summary.Class != InstallClassInProgress {
		t.Fatalf("live owner: %+v %v", summary, err)
	}
}

func TestStatusInstallRecoveryRefusesAmbiguousJournals(t *testing.T) {
	good := statusJournalFixture(JournalRunning, StepInstallerDownloadingLinux, "")
	mutations := map[string]string{
		"duplicate":    strings.Replace(good, `"outcome":"running"`, `"outcome":"armed","outcome":"running"`, 1),
		"unknown":      strings.Replace(good, `"schema":1`, `"schema":1,"extra":"x"`, 1),
		"null":         strings.Replace(good, `"imageRef":"ghcr.io/tuna-os/yellowfin:gnome"`, `"imageRef":null`, 1),
		"schema":       strings.Replace(good, `"schema":1`, `"schema":2`, 1),
		"fraction":     strings.Replace(good, `"pid":4242`, `"pid":42.5`, 1),
		"outcome":      strings.Replace(good, `"outcome":"running"`, `"outcome":"healthy"`, 1),
		"current-step": strings.Replace(good, `"currentStep":"Downloading Linux"`, `"currentStep":"C:\\private"`, 1),
		"missing":      strings.Replace(good, `"completedSteps":["Checking your PC","Preparing Windows"],`, ``, 1),
		"trailing":     good + `{}`,
		"oversized":    strings.Replace(good, `"error"`, `"error"`, 1)[:len(good)-1] + `,"error":"` + strings.Repeat("x", 70*1024) + `"}`,
	}
	for name, journal := range mutations {
		t.Run(name, func(t *testing.T) {
			if journal == good {
				t.Fatal("mutation did not change the fixture")
			}
			root := filepath.Join(t.TempDir(), "wootc")
			writeStatusRecoveryRoot(t, root, journal, statusFixtureStaged)
			if summary, err := readNativeInstallRecovery(root, notRunning); err == nil {
				t.Fatalf("ambiguous journal accepted: %+v", summary)
			}
		})
	}
}

func TestStatusInstallRecoveryRefusesIrregularMarkers(t *testing.T) {
	for _, marker := range []string{filepath.Join("install", "armed.json"), filepath.Join("disks", "root.disk")} {
		t.Run(filepath.Base(marker), func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "wootc")
			writeStatusRecoveryRoot(t, root, statusJournalFixture(JournalRunning, StepInstallerDownloadingLinux, ""), statusFixtureStaged)
			if err := os.MkdirAll(filepath.Join(root, marker), 0700); err != nil {
				t.Fatal(err)
			}
			if _, err := readNativeInstallRecovery(root, notRunning); err == nil {
				t.Fatal("directory marker accepted")
			}
		})
	}
}

func TestStatusJournalOwnerNeedsCreationBeforeJournal(t *testing.T) {
	now := time.Now().UTC()
	self := InstallJournal{PID: os.Getpid(), StartedAt: now.Add(time.Minute).Format(time.RFC3339)}
	if !journalOwnerRunning(self) {
		t.Fatal("running process created before its journal was not recognised")
	}
	reused := InstallJournal{PID: os.Getpid(), StartedAt: now.Add(-24 * time.Hour).Format(time.RFC3339)}
	if journalOwnerRunning(reused) {
		t.Fatal("process created after the journal passed as its owner")
	}
	if journalOwnerRunning(InstallJournal{PID: 0, StartedAt: self.StartedAt}) || journalOwnerRunning(InstallJournal{PID: os.Getpid(), StartedAt: "not-a-time"}) {
		t.Fatal("invalid owner identity passed")
	}
}

func TestStatusInstallRecoveryRPCContract(t *testing.T) {
	app := NewApp()
	server := NewAssessmentServer(app, &synchronizedWriter{out: &bytes.Buffer{}})
	server.strictStartup = true
	calls := 0
	server.startupValidate = func(context.Context) error { calls++; return errors.New("private-path-must-not-cross") }
	result, failure := server.dispatch(context.Background(), jsonrpcRequest{JSONRPC: "2.0", Method: "GetInstallRecovery"})
	if result != nil || failure == nil || failure.Message != "native startup observation refused" || calls != 1 {
		t.Fatalf("drift did not refuse: %v %+v %d", result, failure, calls)
	}
	result, failure = server.dispatch(context.Background(), jsonrpcRequest{JSONRPC: "2.0", Method: "GetInstallRecovery", Params: json.RawMessage(`{"root":"C:\\other"}`)})
	if result != nil || failure == nil || failure.Code != errCodeInvalidParams || calls != 1 {
		t.Fatalf("parameters reached the reader: %v %+v %d", result, failure, calls)
	}
	legacy := NewServer(NewApp(), &synchronizedWriter{out: &bytes.Buffer{}})
	result, failure = legacy.dispatch(context.Background(), jsonrpcRequest{JSONRPC: "2.0", Method: "GetInstallRecovery"})
	if failure != nil || reflect.TypeOf(result) != reflect.TypeOf(InstallRecoverySummary{}) {
		t.Fatalf("legacy contract: %T %+v", result, failure)
	}
}

// The native shell decodes these exact bytes
// (shell/Wootc.Shell.NativeTests/InstallRecoveryProtocolTests.cs).
func TestStatusInstallRecoverySharedGoldens(t *testing.T) {
	interrupted := filepath.Join(t.TempDir(), "wootc")
	writeStatusRecoveryRoot(t, interrupted, statusJournalFixture(JournalRunning, StepInstallerDownloadingLinux, ""), statusFixtureStaged)
	for name, root := range map[string]string{"interrupted.json": interrupted, "none.json": filepath.Join(t.TempDir(), "wootc")} {
		summary, err := readNativeInstallRecovery(root, notRunning)
		if err != nil {
			t.Fatal(err)
		}
		data, err := json.Marshal(summary)
		if err != nil {
			t.Fatal(err)
		}
		path := filepath.Join("..", "tests", "unit", "fixtures", "install-recovery", name)
		if os.Getenv("WOOTC_UPDATE_INSTALL_RECOVERY_GOLDENS") == "1" {
			if err := os.WriteFile(path, data, 0644); err != nil {
				t.Fatal(err)
			}
		}
		golden, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(golden, data) {
			t.Fatalf("%s differs from the engine summary:\n%s\n%s", name, golden, data)
		}
	}
}
