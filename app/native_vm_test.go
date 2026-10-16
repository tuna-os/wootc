package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeVMMachine is the observed VM of a test. Its run action only records
// the plan: no test starts, stops or prepares a VM.
type fakeVMMachine struct {
	installing bool
	state      VMState
	launch     VMCapability
	prepare    VMCapability
	userErr    error
	ran        []NativeVMPlan
	prepares   int
}

func (machine *fakeVMMachine) host() *nativeVMHost {
	return &nativeVMHost{
		session: nativeMaintenanceTestSession, brand: "wootc",
		installing:     func() bool { return machine.installing },
		state:          func() VMState { return machine.state },
		launch:         func() VMCapability { return machine.launch },
		prepare:        func() VMCapability { machine.prepares++; return machine.prepare },
		revalidateUser: func() error { return machine.userErr },
		run:            func(plan NativeVMPlan) error { machine.ran = append(machine.ran, plan); return nil },
	}
}

func absentVM() *fakeVMMachine {
	return &fakeVMMachine{state: VMState{SchemaVersion: 1, Phase: "absent"}, prepare: VMCapability{Available: true, Accelerator: "whpx", QEMUPath: `C:\wootc\qemu\qemu-system-x86_64.exe`}}
}

func stoppedVM() *fakeVMMachine {
	return &fakeVMMachine{
		state:  VMState{SchemaVersion: 1, Phase: vmStopped, Image: "ghcr.io/tuna-os/yellowfin@sha256:" + strings.Repeat("a", 64), Username: "linux_user", DiskPath: `C:\wootc\disks\root.disk`, PID: 4242, RunID: strings.Repeat("b", 32)},
		launch: VMCapability{Available: true, Accelerator: "whpx", QEMUPath: `C:\wootc\qemu\qemu-system-x86_64.exe`, DiskPath: `C:\wootc\disks\root.disk`},
	}
}

func vmServer(machine *fakeVMMachine) *Server {
	session := newNativeInstallSession(grantingPrepare(&fakeNativeInstallAuthority{intent: strings.Repeat("c", 32)}, &[]InstallConfig{}), func(InstallConfig) error { panic("an install started from a VM test") }).
		withMaintenance(installedMachine().host()).withVM(machine.host())
	server := newNativeInstallServer(NewApp(), &synchronizedWriter{out: &bytes.Buffer{}}, session)
	server.strictStartup = true
	server.startupValidate = func(context.Context) error { return nil }
	return server
}

func vmConfirmation(grant NativeVMGrant) string {
	return fmt.Sprintf(`{"kind":"confirm-vm","protocolVersion":1,"session":%q,"brandId":%q,"intentId":%q,"action":%q}`, grant.Session, grant.BrandID, grant.IntentID, grant.Action)
}

const vmPreparePlan = `{"action":"prepare","imageRef":"ghcr.io/tuna-os/yellowfin:gnome","username":"linux_user","password":"public synthetic password"}`

func TestNativeVMPlanAcceptsOnlyItsExactShape(t *testing.T) {
	for _, plan := range []string{vmPreparePlan, `{"action":"boot"}`, `{"action":"stop"}`, `{"action":"force-stop"}`, `{"action":"install-runtime"}`} {
		if _, err := decodeNativeVMPlan(json.RawMessage(plan)); err != nil {
			t.Errorf("%s refused: %v", plan, err)
		}
	}
	for _, plan := range []string{
		``, `null`, `{}`, `{"action":"delete-disk"}`, `{"action":"boot","imageRef":"x"}`, `{"action":"stop","password":"x"}`,
		`{"action":"prepare","imageRef":"ghcr.io/x","username":"root","password":"x"}`, `{"action":"prepare","imageRef":"ghcr.io/x","username":"u"}`,
		`{"action":"prepare","imageRef":"ghcr.io/x","username":"u","password":"a\nb"}`, `{"action":"boot","accelerator":"tcg"}`,
		`{"action":"boot","action":"stop"}`, `{"action":null}`, `{"action":"boot"} {}`,
	} {
		if _, err := decodeNativeVMPlan(json.RawMessage(plan)); err == nil {
			t.Errorf("%q accepted", plan)
		}
	}
}

func TestNativeVMAdmissionFollowsTheEngineObservations(t *testing.T) {
	prepare := NativeVMPlan{Action: "prepare", ImageRef: "ghcr.io/x", Username: "u", Password: "p"}
	cases := []struct {
		name    string
		machine func() *fakeVMMachine
		plan    NativeVMPlan
		refuse  string
	}{
		{"prepare", absentVM, prepare, ""},
		{"prepare unavailable", func() *fakeVMMachine { m := absentVM(); m.prepare = VMCapability{Reason: "synthetic reason"}; return m }, prepare, "synthetic reason"},
		{"prepare over a disk", stoppedVM, prepare, "already prepared"},
		{"install running", func() *fakeVMMachine { m := absentVM(); m.installing = true; return m }, prepare, "installation is running"},
		{"runtime", func() *fakeVMMachine { m := absentVM(); m.prepare = VMCapability{RuntimeNeeded: true}; return m }, NativeVMPlan{Action: "install-runtime"}, ""},
		{"runtime present", absentVM, NativeVMPlan{Action: "install-runtime"}, "not needed"},
		{"boot", stoppedVM, NativeVMPlan{Action: "boot"}, ""},
		{"boot no accelerator", func() *fakeVMMachine {
			m := stoppedVM()
			m.launch = VMCapability{Reason: "No VM accelerator available."}
			return m
		}, NativeVMPlan{Action: "boot"}, "No VM accelerator"},
		{"boot from recovery", func() *fakeVMMachine { m := stoppedVM(); m.state.Phase = vmRecovery; return m }, NativeVMPlan{Action: "boot"}, "cannot start from needs_recovery"},
		{"stop", func() *fakeVMMachine { m := stoppedVM(); m.state.Phase = vmRunning; return m }, NativeVMPlan{Action: "stop"}, ""},
		{"stop stopped", stoppedVM, NativeVMPlan{Action: "stop"}, "no running Linux system"},
		{"force-stop preparing", func() *fakeVMMachine { m := absentVM(); m.state.Phase = vmPreparing; return m }, NativeVMPlan{Action: "force-stop"}, ""},
		{"force-stop stopped", stoppedVM, NativeVMPlan{Action: "force-stop"}, "no active Linux system"},
	}
	for _, c := range cases {
		_, err := admitNativeVMAction(c.plan, c.machine().host().observe())
		if c.refuse == "" && err != nil {
			t.Errorf("%s: refused: %v", c.name, err)
		}
		if c.refuse != "" && (err == nil || !strings.Contains(err.Error(), c.refuse)) {
			t.Errorf("%s: got %v, want a refusal with %q", c.name, err, c.refuse)
		}
	}
}

// The status is a projection: no disk path, process, run ID, QEMU path or
// runtime hash crosses the pipe, and the runtime check runs only when no disk exists.
func TestNativeInstallSessionVMStatusProjectsTheState(t *testing.T) {
	machine := stoppedVM()
	result, failure := maintenanceCall(vmServer(machine), "GetNativeVMStatus", "")
	if failure != nil {
		t.Fatal(failure)
	}
	data, _ := json.Marshal(result)
	for _, private := range []string{"disks", "qemu", "4242", strings.Repeat("b", 32), "diskPath", "pid", "runId"} {
		if strings.Contains(string(data), private) {
			t.Errorf("status carries %q: %s", private, data)
		}
	}
	status := result.(NativeVMStatus)
	if status.SchemaVersion != 1 || status.Phase != vmStopped || !status.Launch.Available || machine.prepares != 0 {
		t.Fatalf("status %+v (runtime checks %d)", status, machine.prepares)
	}
	if _, failure = maintenanceCall(vmServer(machine), "GetNativeVMStatus", `{"probe":true}`); failure == nil {
		t.Fatal("status accepted parameters")
	}
	if _, failure = maintenanceCall(maintenanceServerWithout(), "GetNativeVMStatus", ""); failure == nil || failure.Code != errCodeMethodNotFound {
		t.Fatal("a session without a VM host served the status")
	}
	legacy := NewServer(NewApp(), &synchronizedWriter{out: &bytes.Buffer{}})
	for _, method := range []string{"GetNativeVMStatus", "PrepareNativeVMAction", "ConfirmNativeVMAction"} {
		if _, failure = legacy.dispatch(context.Background(), jsonrpcRequest{Method: method}); failure == nil || failure.Code != errCodeMethodNotFound {
			t.Errorf("legacy server served %s", method)
		}
	}
}

func TestNativeInstallSessionVMActionsRunOnceEachInTurn(t *testing.T) {
	machine := absentVM()
	server := vmServer(machine)
	result, failure := maintenanceCall(server, "PrepareNativeVMAction", vmPreparePlan)
	if failure != nil {
		t.Fatalf("prepare refused: %+v", failure)
	}
	grant := result.(NativeVMGrant)
	data, _ := json.Marshal(grant)
	if grant.SchemaVersion != 1 || grant.Action != "prepare" || grant.ImageRef != "ghcr.io/tuna-os/yellowfin:gnome" || grant.Username != "linux_user" ||
		grant.Phase != "absent" || !lowerHexLength(grant.IntentID, 32) || strings.Contains(string(data), "password") {
		t.Fatalf("grant %s", data)
	}
	if _, failure = maintenanceCall(server, "ConfirmNativeVMAction", vmConfirmation(grant)); failure != nil {
		t.Fatalf("confirmation refused: %+v", failure)
	}
	if len(machine.ran) != 1 || machine.ran[0].Password != "public synthetic password" {
		t.Fatalf("ran %+v", machine.ran)
	}
	if _, failure = maintenanceCall(server, "ConfirmNativeVMAction", vmConfirmation(grant)); failure == nil {
		t.Fatal("a used VM intent ran again")
	}
	// The VM this session started is stopped by the same session, with a new grant.
	machine.state = VMState{SchemaVersion: 1, Phase: vmRunning, Image: "ghcr.io/tuna-os/yellowfin@sha256:" + strings.Repeat("a", 64)}
	result, failure = maintenanceCall(server, "PrepareNativeVMAction", `{"action":"stop"}`)
	if failure != nil {
		t.Fatalf("stop refused: %+v", failure)
	}
	if _, failure = maintenanceCall(server, "ConfirmNativeVMAction", vmConfirmation(result.(NativeVMGrant))); failure != nil || len(machine.ran) != 2 || machine.ran[1].Action != "stop" {
		t.Fatalf("stop: %+v %+v", failure, machine.ran)
	}
	for _, method := range []string{"PrepareNativeInstall", "PrepareNativeMaintenance"} {
		params := nativeInstallPlanFixture
		if method == "PrepareNativeMaintenance" {
			params = `{"action":"uninstall"}`
		}
		if _, failure = maintenanceCall(server, method, params); failure == nil {
			t.Errorf("%s accepted in a VM session", method)
		}
	}
}

func TestNativeInstallSessionVMIntentIsConsumedAndRevalidated(t *testing.T) {
	wrong := []func(NativeVMGrant) string{
		func(g NativeVMGrant) string { g.IntentID = strings.Repeat("0", 32); return vmConfirmation(g) },
		func(g NativeVMGrant) string { g.Action = "force-stop"; return vmConfirmation(g) },
		func(g NativeVMGrant) string { g.BrandID = "bazzite"; return vmConfirmation(g) },
		func(g NativeVMGrant) string {
			return strings.Replace(vmConfirmation(g), `"confirm-vm"`, `"confirm-maintenance"`, 1)
		},
		func(g NativeVMGrant) string { return strings.Replace(vmConfirmation(g), `}`, `,"password":"x"}`, 1) },
	}
	for index, mutate := range wrong {
		machine := stoppedVM()
		server := vmServer(machine)
		result, _ := maintenanceCall(server, "PrepareNativeVMAction", `{"action":"boot"}`)
		grant := result.(NativeVMGrant)
		if _, failure := maintenanceCall(server, "ConfirmNativeVMAction", mutate(grant)); failure == nil {
			t.Errorf("case %d: a mismatched confirmation was accepted", index)
		}
		if _, failure := maintenanceCall(server, "ConfirmNativeVMAction", vmConfirmation(grant)); failure == nil || len(machine.ran) != 0 {
			t.Errorf("case %d: the intent survived a failed first attempt", index)
		}
	}
	changes := map[string]func(*fakeVMMachine){
		"started elsewhere": func(m *fakeVMMachine) { m.state.Phase = vmRunning },
		"image changed":     func(m *fakeVMMachine) { m.state.Image = "ghcr.io/other@sha256:" + strings.Repeat("d", 64) },
		"accelerator lost":  func(m *fakeVMMachine) { m.launch.Available = false },
		"install started":   func(m *fakeVMMachine) { m.installing = true },
		"user replaced":     func(m *fakeVMMachine) { m.userErr = errors.New("native original user changed") },
	}
	for name, change := range changes {
		machine := stoppedVM()
		server := vmServer(machine)
		result, _ := maintenanceCall(server, "PrepareNativeVMAction", `{"action":"boot"}`)
		change(machine)
		if _, failure := maintenanceCall(server, "ConfirmNativeVMAction", vmConfirmation(result.(NativeVMGrant))); failure == nil || len(machine.ran) != 0 {
			t.Errorf("%s: ran after the observation changed", name)
		}
	}
	// A new action replaces an unconfirmed one, whose intent can never run.
	machine := stoppedVM()
	server := vmServer(machine)
	first, _ := maintenanceCall(server, "PrepareNativeVMAction", `{"action":"boot"}`)
	if _, failure := maintenanceCall(server, "PrepareNativeVMAction", `{"action":"boot"}`); failure != nil {
		t.Fatal(failure)
	}
	if _, failure := maintenanceCall(server, "ConfirmNativeVMAction", vmConfirmation(first.(NativeVMGrant))); failure == nil || len(machine.ran) != 0 {
		t.Fatal("a replaced intent ran")
	}
	// An install session that holds a plan takes no VM action.
	installServer := vmServer(absentVM())
	if _, failure := maintenanceCall(installServer, "PrepareNativeMaintenance", `{"action":"uninstall"}`); failure != nil {
		t.Fatal(failure)
	}
	if _, failure := maintenanceCall(installServer, "PrepareNativeVMAction", vmPreparePlan); failure == nil {
		t.Fatal("a VM action was accepted after a maintenance plan")
	}
}

// TestNativeVMRecordedFrames records the engine's VM responses and a
// vm:progress stream (the builder's own reader over a synthetic guest
// output, through the real stdio emitter) for the shell's decoder tests.
// Update: WOOTC_UPDATE_NATIVE_VM_GOLDENS=1 go test -run TestNativeVMRecordedFrames .
func TestNativeVMRecordedFrames(t *testing.T) {
	var responses bytes.Buffer
	record := func(method, params string, machine *fakeVMMachine, fix func(any) any) {
		t.Helper()
		result, failure := maintenanceCall(vmServer(machine), method, params)
		if failure != nil {
			t.Fatalf("%s: %+v", method, failure)
		}
		if fix != nil {
			result = fix(result)
		}
		line, _ := json.Marshal(map[string]any{"method": method, "response": jsonrpcSuccessResponse{JSONRPC: "2.0", ID: json.RawMessage("1"), Result: result}})
		responses.Write(append(line, '\n'))
	}
	needsRuntime := absentVM()
	needsRuntime.prepare = VMCapability{RuntimeNeeded: true, Reason: "This release needs the Linux window runtime. Set it up to check whether this PC can run it."}
	record("GetNativeVMStatus", "", needsRuntime, nil)
	record("GetNativeVMStatus", "", stoppedVM(), nil)
	running := stoppedVM()
	running.state.Phase = vmRunning
	record("GetNativeVMStatus", "", running, nil)
	record("PrepareNativeVMAction", vmPreparePlan, absentVM(), func(result any) any {
		grant := result.(NativeVMGrant)
		grant.IntentID = "fedcba9876543210fedcba9876543210"
		return grant
	})
	var progress bytes.Buffer
	app := NewApp()
	app.SetEmitter(newStdioEmitter(&synchronizedWriter{out: &progress}))
	guest := strings.Join([]string{
		`{"step":"pulling","pct":10,"msg":"guest text is not shown"}`, `not json`, `{"step":"installing","pct":60}`,
		`{"step":"finalizing","pct":95}`, `STATUS=SUCCESS`,
	}, "\n")
	app.emitVM(VMEvent{Stage: "pulling", Message: "Preparing your persistent Linux system. Windows will remain available."})
	if err := readBuilderProgress(strings.NewReader(guest), app.emitVM).verify(nil); err != nil {
		t.Fatal(err)
	}
	app.emitVM(VMEvent{Stage: "started", Message: "Your persistent Linux VM is running. Desktop and account readiness are not yet verified."})
	app.emitVM(VMEvent{Stage: vmStopped})
	dir := filepath.Join("..", "tests", "unit", "fixtures", "native-vm")
	for name, data := range map[string][]byte{"responses.ndjson": responses.Bytes(), "progress.ndjson": progress.Bytes()} {
		path := filepath.Join(dir, name)
		if os.Getenv("WOOTC_UPDATE_NATIVE_VM_GOLDENS") == "1" {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, data, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		want, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(want, data) {
			t.Fatalf("%s differs from the engine's frames (%v); regenerate with WOOTC_UPDATE_NATIVE_VM_GOLDENS=1\ngot:\n%s", path, err, data)
		}
	}
}
