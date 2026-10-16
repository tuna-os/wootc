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

const nativeMaintenanceTestSession = "0123456789abcdef0123456789abcdef"

// fakeMaintenanceMachine is the observed PC of a maintenance test. Its run
// action only records the plan: no test removes, repairs or restarts anything.
type fakeMaintenanceMachine struct {
	running     bool
	info        UninstallInfo
	boot        BootRepairReport
	verdict     RecoveryVerdict
	userErr     error
	ran         []NativeMaintenancePlan
	runErr      error
	inspections int
}

func (machine *fakeMaintenanceMachine) host() *nativeMaintenanceHost {
	return &nativeMaintenanceHost{
		session: nativeMaintenanceTestSession, brand: "wootc",
		running: func() bool { return machine.running },
		info:    func() UninstallInfo { return machine.info },
		boot:    func() BootRepairReport { return machine.boot },
		inspect: func() BootRepairReport {
			machine.inspections++
			report := machine.boot
			report.BundlePath = `C:\wootc\install\repair\synthetic`
			return report
		},
		verdict:        func() RecoveryVerdict { return machine.verdict },
		revalidateUser: func() error { return machine.userErr },
		run: func(plan NativeMaintenancePlan) error {
			machine.ran = append(machine.ran, plan)
			return machine.runErr
		},
	}
}

func installedMachine() *fakeMaintenanceMachine {
	return &fakeMaintenanceMachine{
		info:    UninstallInfo{Found: true, StorageDrive: "D", DiskPath: `D:\wootc\disks\root.disk`, DiskSizeGB: 64, OnDedicatedVol: true, ReclaimGB: 80, VolumeLabel: "wootc-data", Deployed: true},
		boot:    BootRepairReport{BootState: BootStateWootcListed, Ownership: "owned", WootcEntries: []string{"{synthetic}"}, CanRestoreWindows: true, CanRepairBoot: true, Refusals: []string{"synthetic refusal"}},
		verdict: RecoveryVerdict{Verdict: "failed", CanTryAgain: true, Timestamp: "2026-10-15T00:00:00Z"},
	}
}

func maintenanceServer(machine *fakeMaintenanceMachine) *Server {
	session := newNativeInstallSession(nil, func(InstallConfig) error { panic("an install started from a maintenance test") }).withMaintenance(machine.host())
	server := newNativeInstallServer(NewApp(), &synchronizedWriter{out: &bytes.Buffer{}}, session)
	server.strictStartup = true
	server.startupValidate = func(context.Context) error { return nil }
	return server
}

func maintenanceCall(server *Server, method, params string) (any, *jsonrpcError) {
	var raw json.RawMessage
	if params != "" {
		raw = json.RawMessage(params)
	}
	return server.dispatch(context.Background(), jsonrpcRequest{Method: method, Params: raw})
}

func maintenanceConfirmation(grant NativeMaintenanceGrant) string {
	return fmt.Sprintf(`{"kind":"confirm-maintenance","protocolVersion":1,"session":%q,"brandId":%q,"intentId":%q,"action":%q}`, grant.Session, grant.BrandID, grant.IntentID, grant.Action)
}

func TestNativeMaintenancePlanAcceptsOnlyItsExactShape(t *testing.T) {
	for _, plan := range []string{
		`{"action":"uninstall"}`, `{"action":"uninstall","deleteRootDisk":true,"removePartition":true}`,
		`{"action":"repair-boot"}`, `{"action":"restore-windows-boot","deleteRootDisk":false}`, `{"action":"try-again"}`, `{"action":"boot-linux"}`,
	} {
		if _, err := decodeNativeMaintenancePlan(json.RawMessage(plan)); err != nil {
			t.Errorf("%s refused: %v", plan, err)
		}
	}
	for _, plan := range []string{
		``, `null`, `[]`, `{}`, `{"action":"format-disk"}`, `{"action":"Uninstall"}`, `{"action":null}`,
		`{"action":"uninstall","deleteRootDisk":null}`, `{"action":"uninstall","action":"repair-boot"}`,
		`{"action":"uninstall","storageDrive":"C"}`, `{"action":"uninstall"} {}`, `{"action":"uninstall","deleteRootDisk":"yes"}`,
		`{"action":"repair-boot","deleteRootDisk":true}`, `{"action":"boot-linux","removePartition":true}`,
		`{"action":"uninstall","pad":"` + strings.Repeat("x", 1100) + `"}`,
	} {
		if _, err := decodeNativeMaintenancePlan(json.RawMessage(plan)); err == nil {
			t.Errorf("%q accepted", plan)
		}
	}
}

func TestNativeMaintenanceAdmissionFollowsTheEngineObservations(t *testing.T) {
	cases := []struct {
		name   string
		change func(*fakeMaintenanceMachine)
		plan   NativeMaintenancePlan
		refuse string
	}{
		{"uninstall", nil, NativeMaintenancePlan{Action: "uninstall", DeleteRootDisk: true, RemovePartition: true}, ""},
		{"running install", func(m *fakeMaintenanceMachine) { m.running = true }, NativeMaintenancePlan{Action: "uninstall"}, "an installation is running"},
		{"nothing installed", func(m *fakeMaintenanceMachine) { m.info = UninstallInfo{} }, NativeMaintenancePlan{Action: "uninstall"}, "nothing to remove"},
		{"orphaned cleanup", func(m *fakeMaintenanceMachine) { m.info = UninstallInfo{Orphaned: true} }, NativeMaintenancePlan{Action: "uninstall"}, ""},
		{"orphaned data", func(m *fakeMaintenanceMachine) { m.info = UninstallInfo{Orphaned: true} }, NativeMaintenancePlan{Action: "uninstall", DeleteRootDisk: true}, "no Linux data to delete"},
		{"shared volume", func(m *fakeMaintenanceMachine) { m.info.OnDedicatedVol = false }, NativeMaintenancePlan{Action: "uninstall", RemovePartition: true}, "was not created for this installation"},
		{"engine reason", func(m *fakeMaintenanceMachine) {
			m.info.OnDedicatedVol, m.info.PartitionRemovalReason = false, "synthetic engine reason"
		}, NativeMaintenancePlan{Action: "uninstall", RemovePartition: true}, "synthetic engine reason"},
		{"repair", nil, NativeMaintenancePlan{Action: "repair-boot"}, ""},
		{"repair refused", func(m *fakeMaintenanceMachine) { m.boot.CanRepairBoot = false }, NativeMaintenancePlan{Action: "repair-boot"}, "repair refused, nothing was changed: synthetic refusal"},
		{"restore", nil, NativeMaintenancePlan{Action: "restore-windows-boot"}, ""},
		{"restore refused", func(m *fakeMaintenanceMachine) { m.boot.CanRestoreWindows = false }, NativeMaintenancePlan{Action: "restore-windows-boot"}, "cannot be restored from here"},
		{"try again", nil, NativeMaintenancePlan{Action: "try-again"}, ""},
		{"no attempt", func(m *fakeMaintenanceMachine) { m.verdict = RecoveryVerdict{} }, NativeMaintenancePlan{Action: "try-again"}, "no recorded installation attempt"},
		{"boot linux", nil, NativeMaintenancePlan{Action: "boot-linux"}, ""},
		{"not deployed", func(m *fakeMaintenanceMachine) { m.info.Deployed = false }, NativeMaintenancePlan{Action: "boot-linux"}, "has not finished"},
	}
	for _, c := range cases {
		machine := installedMachine()
		if c.change != nil {
			c.change(machine)
		}
		_, err := admitNativeMaintenance(c.plan, machine.host().observe())
		if c.refuse == "" && err != nil {
			t.Errorf("%s: refused: %v", c.name, err)
		}
		if c.refuse != "" && (err == nil || !strings.Contains(err.Error(), c.refuse)) {
			t.Errorf("%s: got %v, want a refusal with %q", c.name, err, c.refuse)
		}
	}
}

func TestNativeInstallSessionMaintenanceReadsBeforeAPlan(t *testing.T) {
	machine := installedMachine()
	server := maintenanceServer(machine)
	info, failure := maintenanceCall(server, "GetUninstallInfo", "")
	if failure != nil || info.(UninstallInfo).DiskPath != machine.info.DiskPath {
		t.Fatalf("uninstall info: %+v %+v", info, failure)
	}
	report, failure := maintenanceCall(server, "InspectBoot", "null")
	if failure != nil || report.(BootRepairReport).BundlePath == "" || machine.inspections != 1 {
		t.Fatalf("boot check: %+v %+v", report, failure)
	}
	if _, failure = maintenanceCall(server, "InspectBoot", `{"repair":true}`); failure == nil || failure.Code != errCodeInvalidParams {
		t.Fatalf("boot check accepted parameters: %+v", failure)
	}
	for _, method := range []string{"GetUninstallInfo", "InspectBoot"} {
		if _, failure = maintenanceCall(maintenanceServerWithout(), method, ""); failure == nil || failure.Code != errCodeMethodNotFound {
			t.Errorf("%s served without a maintenance host: %+v", method, failure)
		}
		legacy := NewServer(NewApp(), &synchronizedWriter{out: &bytes.Buffer{}})
		for _, method := range []string{"PrepareNativeMaintenance", "ConfirmNativeMaintenance"} {
			if _, failure = legacy.dispatch(context.Background(), jsonrpcRequest{Method: method}); failure == nil || failure.Code != errCodeMethodNotFound {
				t.Errorf("legacy server served %s: %+v", method, failure)
			}
		}
	}
	if len(machine.ran) != 0 {
		t.Fatal("a read ran a maintenance action")
	}
}

func maintenanceServerWithout() *Server {
	return newNativeInstallServer(NewApp(), &synchronizedWriter{out: &bytes.Buffer{}}, newNativeInstallSession(nil, nil))
}

func TestNativeInstallSessionMaintenanceRunsTheGrantedPlanOnce(t *testing.T) {
	machine := installedMachine()
	server := maintenanceServer(machine)
	result, failure := maintenanceCall(server, "PrepareNativeMaintenance", `{"action":"uninstall","deleteRootDisk":true}`)
	if failure != nil {
		t.Fatalf("plan refused: %+v", failure)
	}
	grant := result.(NativeMaintenanceGrant)
	if grant.SchemaVersion != 1 || grant.Session != nativeMaintenanceTestSession || grant.BrandID != "wootc" || !lowerHexLength(grant.IntentID, 32) ||
		grant.Action != "uninstall" || !grant.DeleteRootDisk || grant.RemovePartition || grant.DiskPath != machine.info.DiskPath ||
		grant.StorageDrive != "D" || grant.VolumeLabel != "wootc-data" || grant.BootState != BootStateWootcListed {
		t.Fatalf("grant does not disclose the admitted plan: %+v", grant)
	}
	if _, failure = maintenanceCall(server, "PrepareNativeMaintenance", `{"action":"uninstall"}`); failure == nil {
		t.Fatal("a second plan was accepted in one session")
	}
	if _, failure = maintenanceCall(server, "PrepareNativeInstall", nativeInstallPlanFixture); failure == nil {
		t.Fatal("an install plan was accepted in a maintenance session")
	}
	if _, failure = maintenanceCall(server, "ConfirmNativeMaintenance", maintenanceConfirmation(grant)); failure != nil {
		t.Fatalf("confirmation refused: %+v", failure)
	}
	if len(machine.ran) != 1 || machine.ran[0] != (NativeMaintenancePlan{Action: "uninstall", DeleteRootDisk: true}) {
		t.Fatalf("ran %+v", machine.ran)
	}
	for _, method := range []string{"ConfirmNativeMaintenance", "ConfirmNativeInstall"} {
		if _, failure = maintenanceCall(server, method, maintenanceConfirmation(grant)); failure == nil {
			t.Errorf("%s accepted after the intent was used", method)
		}
	}
	if _, failure = maintenanceCall(server, "Reboot", ""); failure == nil {
		t.Fatal("a maintenance session offered the install restart")
	}
	if len(machine.ran) != 1 {
		t.Fatalf("the plan ran %d times", len(machine.ran))
	}
}

func TestNativeInstallSessionMaintenanceConsumesTheIntentOnAnyFirstAttempt(t *testing.T) {
	grantFor := func(machine *fakeMaintenanceMachine, server *Server, plan string) NativeMaintenanceGrant {
		t.Helper()
		result, failure := maintenanceCall(server, "PrepareNativeMaintenance", plan)
		if failure != nil {
			t.Fatalf("plan refused: %+v", failure)
		}
		return result.(NativeMaintenanceGrant)
	}
	wrong := []func(NativeMaintenanceGrant) string{
		func(g NativeMaintenanceGrant) string {
			g.IntentID = strings.Repeat("0", 32)
			return maintenanceConfirmation(g)
		},
		func(g NativeMaintenanceGrant) string { g.Action = "uninstall"; return maintenanceConfirmation(g) },
		func(g NativeMaintenanceGrant) string { g.BrandID = "bazzite"; return maintenanceConfirmation(g) },
		func(g NativeMaintenanceGrant) string {
			g.Session = strings.Repeat("f", 32)
			return maintenanceConfirmation(g)
		},
		func(g NativeMaintenanceGrant) string {
			return strings.Replace(maintenanceConfirmation(g), `"confirm-maintenance"`, `"confirm-install"`, 1)
		},
		func(g NativeMaintenanceGrant) string {
			return strings.Replace(maintenanceConfirmation(g), `}`, `,"deleteRootDisk":true}`, 1)
		},
		func(NativeMaintenanceGrant) string { return `{"kind":"confirm-maintenance"}` },
	}
	for index, mutate := range wrong {
		machine := installedMachine()
		server := maintenanceServer(machine)
		grant := grantFor(machine, server, `{"action":"repair-boot"}`)
		if _, failure := maintenanceCall(server, "ConfirmNativeMaintenance", mutate(grant)); failure == nil {
			t.Errorf("case %d: a mismatched confirmation was accepted", index)
		}
		if _, failure := maintenanceCall(server, "ConfirmNativeMaintenance", maintenanceConfirmation(grant)); failure == nil {
			t.Errorf("case %d: the intent survived a failed first attempt", index)
		}
		if len(machine.ran) != 0 {
			t.Errorf("case %d: ran %+v", index, machine.ran)
		}
	}
}

func TestNativeInstallSessionMaintenanceRevalidatesBeforeItRuns(t *testing.T) {
	changes := map[string]func(*fakeMaintenanceMachine){
		"install started":     func(m *fakeMaintenanceMachine) { m.running = true },
		"disk moved":          func(m *fakeMaintenanceMachine) { m.info.DiskPath = `E:\wootc\disks\root.disk` },
		"volume relabelled":   func(m *fakeMaintenanceMachine) { m.info.VolumeLabel = "data" },
		"boot changed":        func(m *fakeMaintenanceMachine) { m.boot.BootState = BootStateForeignNext },
		"repair now refused":  func(m *fakeMaintenanceMachine) { m.boot.CanRepairBoot = false },
		"user token replaced": func(m *fakeMaintenanceMachine) { m.userErr = errors.New("native original user changed") },
	}
	for name, change := range changes {
		for _, plan := range []string{`{"action":"uninstall","removePartition":true}`, `{"action":"repair-boot"}`} {
			machine := installedMachine()
			server := maintenanceServer(machine)
			result, failure := maintenanceCall(server, "PrepareNativeMaintenance", plan)
			if failure != nil {
				t.Fatalf("%s: plan refused: %+v", name, failure)
			}
			change(machine)
			_, failure = maintenanceCall(server, "ConfirmNativeMaintenance", maintenanceConfirmation(result.(NativeMaintenanceGrant)))
			relevant := !(strings.Contains(plan, "uninstall") && (name == "boot changed" || name == "repair now refused")) &&
				!(strings.Contains(plan, "repair") && (name == "disk moved" || name == "volume relabelled"))
			if relevant && (failure == nil || len(machine.ran) != 0) {
				t.Errorf("%s / %s: ran after the observation changed: %+v %+v", name, plan, failure, machine.ran)
			}
			if !relevant && (failure != nil || len(machine.ran) != 1) {
				t.Errorf("%s / %s: an unrelated change refused the plan: %+v", name, plan, failure)
			}
		}
	}
	machine := installedMachine()
	machine.runErr = errors.New("synthetic uninstall failure")
	server := maintenanceServer(machine)
	result, _ := maintenanceCall(server, "PrepareNativeMaintenance", `{"action":"uninstall"}`)
	if _, failure := maintenanceCall(server, "ConfirmNativeMaintenance", maintenanceConfirmation(result.(NativeMaintenanceGrant))); failure == nil || failure.Message != "synthetic uninstall failure" {
		t.Fatalf("the action's failure was not reported: %+v", failure)
	}
}

func TestNativeInstallSessionMaintenanceRefusalsRunNothing(t *testing.T) {
	machine := installedMachine()
	machine.boot.CanRepairBoot = false
	server := maintenanceServer(machine)
	if _, failure := maintenanceCall(server, "PrepareNativeMaintenance", `{"action":"repair-boot"}`); failure == nil || !strings.Contains(failure.Message, "repair refused, nothing was changed") {
		t.Fatalf("refusal text: %+v", failure)
	}
	if _, failure := maintenanceCall(server, "PrepareNativeMaintenance", `{"action":"uninstall"}`); failure == nil {
		t.Fatal("a refused session accepted a second plan")
	}
	if _, failure := maintenanceCall(server, "ConfirmNativeMaintenance", `{}`); failure == nil || len(machine.ran) != 0 {
		t.Fatal("a refused plan could still be confirmed")
	}
	if _, failure := maintenanceCall(maintenanceServerWithout(), "PrepareNativeMaintenance", `{"action":"uninstall"}`); failure == nil {
		t.Fatal("a session without a maintenance host granted a plan")
	}
}

// The authority is single use by itself, not only because the session drops it.
func TestNativeMaintenanceAuthorizationIsSingleUse(t *testing.T) {
	machine := installedMachine()
	authority, grant, err := machine.host().prepare(NativeMaintenancePlan{Action: "restore-windows-boot"})
	if err != nil {
		t.Fatal(err)
	}
	if authority.confirm([]byte(`{}`)) == nil {
		t.Fatal("a malformed confirmation was accepted")
	}
	if authority.confirm([]byte(maintenanceConfirmation(grant))) == nil || len(machine.ran) != 0 {
		t.Fatal("the intent survived its first attempt")
	}
	authority, grant, _ = machine.host().prepare(NativeMaintenancePlan{Action: "restore-windows-boot"})
	if err := authority.confirm([]byte(maintenanceConfirmation(grant))); err != nil || len(machine.ran) != 1 {
		t.Fatalf("a fresh intent was refused: %v", err)
	}
	if authority.confirm([]byte(maintenanceConfirmation(grant))) == nil || len(machine.ran) != 1 {
		t.Fatal("a used intent ran again")
	}
}

// TestNativeMaintenanceRecordedResponses records the engine's responses for
// the maintenance methods, through the real dispatcher and JSON encoding,
// for the shell's decoder tests (Wootc.Shell.NativeTests). The intent is
// random, so the recording fixes it after the grant.
// Update: WOOTC_UPDATE_NATIVE_MAINTENANCE_GOLDENS=1 go test -run TestNativeMaintenanceRecordedResponses .
func TestNativeMaintenanceRecordedResponses(t *testing.T) {
	machine := installedMachine()
	machine.boot.BundlePath = ""
	machine.boot.ObservedAt = "2026-10-15T00:00:00Z"
	machine.boot.Recommended = BootActionRepairBoot
	machine.boot.Findings = []string{"public synthetic finding"}
	server := maintenanceServer(machine)
	var out bytes.Buffer
	record := func(method, params string, fix func(any) any) {
		t.Helper()
		result, failure := maintenanceCall(server, method, params)
		if failure != nil {
			t.Fatalf("%s: %+v", method, failure)
		}
		if fix != nil {
			result = fix(result)
		}
		line, err := json.Marshal(map[string]any{"method": method, "response": jsonrpcSuccessResponse{JSONRPC: "2.0", ID: json.RawMessage("1"), Result: result}})
		if err != nil {
			t.Fatal(err)
		}
		out.Write(append(line, '\n'))
	}
	record("GetUninstallInfo", "", nil)
	machine.info = UninstallInfo{Orphaned: true}
	record("GetUninstallInfo", "", nil)
	record("InspectBoot", "", func(result any) any {
		report := result.(BootRepairReport)
		report.BundlePath = `C:\wootc\install\repair\public-synthetic`
		return report
	})
	machine.info = installedMachine().info
	record("PrepareNativeMaintenance", `{"action":"uninstall","deleteRootDisk":true,"removePartition":true}`, func(result any) any {
		grant := result.(NativeMaintenanceGrant)
		grant.IntentID = "fedcba9876543210fedcba9876543210"
		return grant
	})
	path := filepath.Join("..", "tests", "unit", "fixtures", "native-maintenance", "responses.ndjson")
	if os.Getenv("WOOTC_UPDATE_NATIVE_MAINTENANCE_GOLDENS") == "1" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, out.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("recorded responses are missing: %v", err)
	}
	if !bytes.Equal(want, out.Bytes()) {
		t.Fatalf("%s differs from the engine's responses; regenerate with WOOTC_UPDATE_NATIVE_MAINTENANCE_GOLDENS=1\nwant:\n%s\ngot:\n%s", path, want, out.Bytes())
	}
}
