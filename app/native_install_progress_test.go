package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestNativeInstallSessionRestartOnlyAfterItsOwnFinishedInstall(t *testing.T) {
	authority := &fakeNativeInstallAuthority{intent: "0123456789abcdef0123456789abcdef", expected: `{"kind":"confirm-install"}`}
	var plans []InstallConfig
	restarts := 0
	session := newNativeInstallSession(grantingPrepare(authority, &plans), func(InstallConfig) error { return nil }).withReboot(func() error { restarts++; return nil })
	app := NewApp()
	server := newNativeInstallServer(app, &synchronizedWriter{out: &bytes.Buffer{}}, session)
	call := func(method, params string) *jsonrpcError {
		_, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: method, Params: json.RawMessage(params)})
		return failure
	}
	app.setStatus(InstallStatus{Done: true})
	if call("Reboot", "") == nil {
		t.Fatal("restart before this session confirmed an install")
	}
	call("PrepareNativeInstall", nativeInstallPlanFixture)
	if call("ConfirmNativeInstall", `{"kind":"confirm-install"}`) != nil {
		t.Fatal("confirmation refused")
	}
	for name, status := range map[string]InstallStatus{
		"running": {Running: true},
		"failed":  {Done: true, Error: "public synthetic failure"},
		"pending": {},
	} {
		app.setStatus(status)
		if call("Reboot", "") == nil {
			t.Fatalf("restart allowed while %s", name)
		}
	}
	app.setStatus(InstallStatus{Done: true})
	if call("Reboot", `{"force":true}`) == nil {
		t.Fatal("restart accepted parameters")
	}
	if restarts != 0 {
		t.Fatal("a refused restart ran")
	}
	if failure := call("Reboot", ""); failure != nil || restarts != 1 {
		t.Fatalf("finished install could not restart: %+v %d", failure, restarts)
	}
	failing := newNativeInstallSession(nil, nil).withReboot(func() error { return errors.New("restart refused by Windows") })
	failing.started = true
	if _, failure := failing.restart(InstallStatus{Done: true}); failure == nil || failure.Message != "restart refused by Windows" {
		t.Fatalf("restart failure lost: %+v", failure)
	}
}

// The native shell replays these exact notification frames
// (shell/Wootc.Shell.Tests/InstallProgressTests.cs and the native session
// tests). They come from the real stdio emitter and the real pipeline's event
// constructors, so no install runs to record them.
func TestNativeInstallProgressRecordedStreams(t *testing.T) {
	// The goldens are the generic build's stream; a local brand overlay must
	// not change the done message they record.
	wearBrand(t, "wootc")
	record := func(events []ProgressEvent) []byte {
		var out bytes.Buffer
		emitter := newStdioEmitter(&synchronizedWriter{out: &out})
		for _, event := range events {
			emitter.Emit("install:progress", event)
		}
		return out.Bytes()
	}
	steps := InstallerSteps()
	upTo := func(last string) []ProgressEvent {
		var events []ProgressEvent
		for index, step := range steps {
			events = append(events, installStepProgress(step.ID, float64(5+index*90/len(steps))))
			if step.ID == last {
				break
			}
		}
		return events
	}
	failure := errors.New("public synthetic step failure")
	streams := map[string][]ProgressEvent{
		"success.ndjson":            append(upTo(""), installDoneEvent()),
		"failure-before-arm.ndjson": append(upTo(StepInstallerDownloadingLinux), installFailureEvent(failure)),
		"failure-after-arm.ndjson":  append(upTo(StepInstallerSavingYourSettings), installFailureEvent(failure)),
	}
	for name, events := range streams {
		data := record(events)
		path := filepath.Join("..", "tests", "unit", "fixtures", "install-progress", name)
		if os.Getenv("WOOTC_UPDATE_INSTALL_PROGRESS_GOLDENS") == "1" {
			if err := os.WriteFile(path, data, 0644); err != nil {
				t.Fatal(err)
			}
		}
		golden, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(golden, data) {
			t.Fatalf("%s differs from the engine's events:\n%s", name, data)
		}
	}
}
