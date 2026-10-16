package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// fakeNativeInstallAuthority stands in for the Windows one-shot authority on
// every platform: it runs the action at most once, on the first attempt, and
// only for the exact confirmation it expects. No test action touches a disk.
type fakeNativeInstallAuthority struct {
	intent, expected string
	attempts         int
}

func (authority *fakeNativeInstallAuthority) intentID() string { return authority.intent }
func (authority *fakeNativeInstallAuthority) confirmIntent(data []byte, action func(InstallConfig) error) error {
	authority.attempts++
	if authority.attempts > 1 {
		return errors.New("native install intent already consumed")
	}
	if string(data) != authority.expected {
		return errors.New("native install confirmation binding refused")
	}
	return action(InstallConfig{ImageRef: "prepared-image", Password: "prepared synthetic password"})
}

const nativeInstallPlanFixture = `{"imageRef":"ghcr.io/tuna-os/yellowfin:gnome","diskSizeGB":40,"username":"linux_user","password":"public synthetic password","hostname":"linux-pc","bootloader":"auto","composeFs":false,"storageDrive":"D","encryption":"none","luksPassphrase":"","windowsLook":false}`

func nativeInstallTestServer(t *testing.T, prepare nativeInstallPrepare, start func(InstallConfig) error) *Server {
	t.Helper()
	server := newNativeInstallServer(NewApp(), &synchronizedWriter{out: &bytes.Buffer{}}, newNativeInstallSession(prepare, start))
	server.strictStartup = true
	server.startupValidate = func(context.Context) error { return nil }
	return server
}

func grantingPrepare(authority *fakeNativeInstallAuthority, plans *[]InstallConfig) nativeInstallPrepare {
	return func(plan InstallConfig) (nativeInstallAuthority, NativeInstallGrant, error) {
		*plans = append(*plans, plan)
		return authority, NativeInstallGrant{SchemaVersion: 1, IntentID: authority.intent, ImageRef: plan.ImageRef}, nil
	}
}

func TestNativeInstallSessionAllowsOnlyStatusCancelPlanAndConsent(t *testing.T) {
	prepared := 0
	server := nativeInstallTestServer(t, func(InstallConfig) (nativeInstallAuthority, NativeInstallGrant, error) {
		prepared++
		return nil, NativeInstallGrant{}, errors.New("unused")
	}, func(InstallConfig) error { t.Fatal("start reached"); return nil })
	allowed := map[string]bool{"GetStatus": true, "CancelInstall": true, "PrepareNativeInstall": true, "ConfirmNativeInstall": true, "Reboot": true, "GetNativeVMStatus": true, "PrepareNativeVMAction": true, "ConfirmNativeVMAction": true, "GetUninstallInfo": true, "InspectBoot": true, "PrepareNativeMaintenance": true, "ConfirmNativeMaintenance": true}
	methods := append(append([]string{}, ProtocolMethods...), "StartInstall", "startinstall", "GetNativeConfiguration", "Unknown")
	for _, method := range methods {
		if allowed[method] {
			continue
		}
		_, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: method, Params: json.RawMessage(`"malformed-cross-method-params"`)})
		if failure == nil || failure.Code != errCodeMethodNotFound {
			t.Errorf("%s reached the backend in an install session: %+v", method, failure)
		}
	}
	if prepared != 0 {
		t.Fatal("refused methods reached preparation")
	}
}

func TestNativeInstallSessionMethodsAreRefusedOutsideInstallSessions(t *testing.T) {
	for name, server := range map[string]*Server{
		"assessment": NewAssessmentServer(NewApp(), &synchronizedWriter{out: &bytes.Buffer{}}),
		"legacy":     NewServer(NewApp(), &synchronizedWriter{out: &bytes.Buffer{}}),
	} {
		for _, method := range []string{"PrepareNativeInstall", "ConfirmNativeInstall"} {
			_, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: method, Params: json.RawMessage(nativeInstallPlanFixture)})
			if failure == nil || failure.Code != errCodeMethodNotFound {
				t.Errorf("%s session accepted %s: %+v", name, method, failure)
			}
		}
	}
}

func TestNativeInstallSessionPlanDecodeRefusesAmbiguousOrForeignFields(t *testing.T) {
	cases := map[string]string{
		"fault-injection":  strings.Replace(nativeInstallPlanFixture, `"windowsLook":false`, `"windowsLook":false,"faultInject":"root-disk"`, 1),
		"session-consent":  strings.Replace(nativeInstallPlanFixture, `"windowsLook":false`, `"windowsLook":false,"sessionConsent":{"browser":true}`, 1),
		"duplicate":        strings.Replace(nativeInstallPlanFixture, `"diskSizeGB":40`, `"diskSizeGB":40,"diskSizeGB":4000`, 1),
		"case-variant":     strings.Replace(nativeInstallPlanFixture, `"storageDrive"`, `"StorageDrive"`, 1),
		"null":             strings.Replace(nativeInstallPlanFixture, `"hostname":"linux-pc"`, `"hostname":null`, 1),
		"trailing":         nativeInstallPlanFixture + `{}`,
		"missing-password": strings.Replace(nativeInstallPlanFixture, `"password":"public synthetic password",`, ``, 1),
		"missing-storage":  strings.Replace(nativeInstallPlanFixture, `"storageDrive":"D",`, ``, 1),
		"array":            `[` + nativeInstallPlanFixture + `]`,
		"oversized":        strings.Replace(nativeInstallPlanFixture, `"linux-pc"`, `"`+strings.Repeat("x", 17000)+`"`, 1),
	}
	for name, plan := range cases {
		t.Run(name, func(t *testing.T) {
			if plan == nativeInstallPlanFixture {
				t.Fatal("mutation did not change the plan")
			}
			calls := 0
			server := nativeInstallTestServer(t, func(InstallConfig) (nativeInstallAuthority, NativeInstallGrant, error) {
				calls++
				return nil, NativeInstallGrant{}, nil
			}, nil)
			_, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: "PrepareNativeInstall", Params: json.RawMessage(plan)})
			if failure == nil || failure.Code != errCodeInvalidParams || calls != 0 {
				t.Fatalf("ambiguous plan reached preparation: %+v %d", failure, calls)
			}
		})
	}
}

func TestNativeInstallSessionHoldsOnePlanAndOneConfirmation(t *testing.T) {
	authority := &fakeNativeInstallAuthority{intent: "0123456789abcdef0123456789abcdef", expected: `{"kind":"confirm-install"}`}
	var plans []InstallConfig
	var started []InstallConfig
	server := nativeInstallTestServer(t, grantingPrepare(authority, &plans), func(config InstallConfig) error {
		started = append(started, config)
		return nil
	})
	call := func(method, params string) (any, *jsonrpcError) {
		return server.dispatch(context.Background(), jsonrpcRequest{Method: method, Params: json.RawMessage(params)})
	}
	result, failure := call("PrepareNativeInstall", nativeInstallPlanFixture)
	grant, ok := result.(NativeInstallGrant)
	if failure != nil || !ok || grant.IntentID != authority.intent || len(plans) != 1 || plans[0].StorageDrive != "D" || plans[0].Password != "public synthetic password" {
		t.Fatalf("plan was not granted: %+v %+v %+v", result, failure, plans)
	}
	if _, failure = call("PrepareNativeInstall", nativeInstallPlanFixture); failure == nil || len(plans) != 1 {
		t.Fatal("a second plan reused the install session")
	}
	if len(started) != 0 {
		t.Fatal("preparation started an install")
	}
	if _, failure = call("ConfirmNativeInstall", `{"kind":"confirm-install"}`); failure != nil || len(started) != 1 || started[0].ImageRef != "prepared-image" {
		t.Fatalf("confirmed intent did not start the prepared plan once: %+v %+v", failure, started)
	}
	if _, failure = call("ConfirmNativeInstall", `{"kind":"confirm-install"}`); failure == nil || len(started) != 1 {
		t.Fatal("a consumed intent started a second install")
	}
}

func TestNativeInstallSessionFirstConfirmationConsumesTheIntent(t *testing.T) {
	for name, first := range map[string]string{"wrong": `{"kind":"other"}`, "empty": ``} {
		t.Run(name, func(t *testing.T) {
			authority := &fakeNativeInstallAuthority{intent: "0123456789abcdef0123456789abcdef", expected: `{"kind":"confirm-install"}`}
			var plans []InstallConfig
			starts := 0
			server := nativeInstallTestServer(t, grantingPrepare(authority, &plans), func(InstallConfig) error { starts++; return nil })
			server.dispatch(context.Background(), jsonrpcRequest{Method: "PrepareNativeInstall", Params: json.RawMessage(nativeInstallPlanFixture)})
			if _, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: "ConfirmNativeInstall", Params: json.RawMessage(first)}); failure == nil {
				t.Fatal("a wrong confirmation was accepted")
			}
			if _, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: "ConfirmNativeInstall", Params: json.RawMessage(`{"kind":"confirm-install"}`)}); failure == nil || starts != 0 {
				t.Fatal("a wrong first confirmation left a reusable intent")
			}
		})
	}
}

func TestNativeInstallSessionRefusesWithoutAPlanOrAfterRefusalOrDrift(t *testing.T) {
	starts := 0
	start := func(InstallConfig) error { starts++; return nil }
	refused := nativeInstallTestServer(t, func(InstallConfig) (nativeInstallAuthority, NativeInstallGrant, error) {
		return nil, NativeInstallGrant{}, errors.New("BitLocker drive encryption isn't supported in the alpha yet")
	}, start)
	_, failure := refused.dispatch(context.Background(), jsonrpcRequest{Method: "PrepareNativeInstall", Params: json.RawMessage(nativeInstallPlanFixture)})
	if failure == nil || !strings.Contains(failure.Message, "BitLocker drive encryption isn't supported") {
		t.Fatalf("engine refusal text was not returned: %+v", failure)
	}
	for _, server := range []*Server{refused, nativeInstallTestServer(t, nil, start)} {
		if _, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: "ConfirmNativeInstall", Params: json.RawMessage(`{"kind":"confirm-install"}`)}); failure == nil {
			t.Fatal("confirmation without a granted plan was accepted")
		}
	}
	mismatched := &fakeNativeInstallAuthority{intent: "0123456789abcdef0123456789abcdef"}
	wrongGrant := nativeInstallTestServer(t, func(InstallConfig) (nativeInstallAuthority, NativeInstallGrant, error) {
		return mismatched, NativeInstallGrant{IntentID: "ffffffffffffffffffffffffffffffff"}, nil
	}, start)
	if _, failure := wrongGrant.dispatch(context.Background(), jsonrpcRequest{Method: "PrepareNativeInstall", Params: json.RawMessage(nativeInstallPlanFixture)}); failure == nil {
		t.Fatal("a grant that names another intent was returned")
	}
	authority := &fakeNativeInstallAuthority{intent: "0123456789abcdef0123456789abcdef", expected: `{"kind":"confirm-install"}`}
	var plans []InstallConfig
	drift := nativeInstallTestServer(t, grantingPrepare(authority, &plans), start)
	drift.dispatch(context.Background(), jsonrpcRequest{Method: "PrepareNativeInstall", Params: json.RawMessage(nativeInstallPlanFixture)})
	drift.startupValidate = func(context.Context) error { return errors.New("private-path-must-not-cross") }
	if _, failure := drift.dispatch(context.Background(), jsonrpcRequest{Method: "ConfirmNativeInstall", Params: json.RawMessage(`{"kind":"confirm-install"}`)}); failure == nil || failure.Message != "native startup observation refused" {
		t.Fatalf("drift did not refuse confirmation: %+v", failure)
	}
	if starts != 0 {
		t.Fatal("a refused path started an install")
	}
}

func nativeInstallSnapshot() NativeConfigurationSnapshot {
	return NativeConfigurationSnapshot{StorageStatus: "observed",
		Images: []NativeConfigurationImage{
			{Image: Image{ImageRef: "ghcr.io/tuna-os/yellowfin:gnome"}, Admitted: true},
			{Image: Image{ImageRef: "ghcr.io/tuna-os/experimental:gnome"}, Admitted: false, AdmissionBlockedReason: "This image is not admitted on the alpha channel."},
		},
		Storage: []NativeConfigurationStorage{
			{ID: "volume-d", DriveLetter: "D", DiskGUID: "11111111-1111-1111-1111-111111111111", PartitionGUID: "22222222-2222-2222-2222-222222222222", NtfsSerial: "0123456789abcdef", MaximumRootDiskSizeGB: 100},
		}}
}

func TestNativeInstallPlanBindsToAnObservedVolumeAndAdmittedImage(t *testing.T) {
	plan := InstallConfig{ImageRef: "ghcr.io/tuna-os/yellowfin:gnome", StorageDrive: "D", DiskSizeGB: 40}
	binding, err := bindNativeInstallPlan(nativeInstallSnapshot(), plan)
	if err != nil || binding.volume.ID != "volume-d" {
		t.Fatalf("observed plan refused: %v", err)
	}
	refusals := map[string]func(*NativeConfigurationSnapshot, *InstallConfig){
		"unobserved-storage": func(s *NativeConfigurationSnapshot, _ *InstallConfig) { s.StorageStatus = "unavailable" },
		"unknown-drive":      func(_ *NativeConfigurationSnapshot, p *InstallConfig) { p.StorageDrive = "E" },
		"too-large":          func(_ *NativeConfigurationSnapshot, p *InstallConfig) { p.DiskSizeGB = 101 },
		"too-small":          func(_ *NativeConfigurationSnapshot, p *InstallConfig) { p.DiskSizeGB = 19 },
		"unknown-image":      func(_ *NativeConfigurationSnapshot, p *InstallConfig) { p.ImageRef = "ghcr.io/example/other:latest" },
		"not-admitted": func(_ *NativeConfigurationSnapshot, p *InstallConfig) {
			p.ImageRef = "ghcr.io/tuna-os/experimental:gnome"
		},
		"ambiguous-drive": func(s *NativeConfigurationSnapshot, _ *InstallConfig) {
			s.Storage = append(s.Storage, s.Storage[0])
		},
	}
	for name, mutate := range refusals {
		t.Run(name, func(t *testing.T) {
			snapshot, changed := nativeInstallSnapshot(), plan
			mutate(&snapshot, &changed)
			if _, err := bindNativeInstallPlan(snapshot, changed); err == nil {
				t.Fatal("plan bound to an unobserved or refused target")
			}
		})
	}
	for name, mutate := range map[string]func(*NativeConfigurationStorage){
		"disk":      func(v *NativeConfigurationStorage) { v.DiskGUID = "33333333-3333-3333-3333-333333333333" },
		"partition": func(v *NativeConfigurationStorage) { v.PartitionGUID = "44444444-4444-4444-4444-444444444444" },
		"serial":    func(v *NativeConfigurationStorage) { v.NtfsSerial = "fedcba9876543210" },
		"identity":  func(v *NativeConfigurationStorage) { v.ID = "volume-other" },
	} {
		t.Run("changed-"+name, func(t *testing.T) {
			snapshot := nativeInstallSnapshot()
			mutate(&snapshot.Storage[0])
			if binding.unchangedIn(snapshot, plan) == nil {
				t.Fatal("a changed volume kept the plan")
			}
		})
	}
	if err := binding.unchangedIn(nativeInstallSnapshot(), plan); err != nil {
		t.Fatalf("an unchanged volume refused: %v", err)
	}
}
