package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"testing"
)

func assessmentWireRequest(t *testing.T, wire string) jsonrpcRequest {
	t.Helper()
	var req jsonrpcRequest
	if err := json.Unmarshal([]byte(wire), &req); err != nil {
		t.Fatal(err)
	}
	return req
}

func TestAssessmentRPCObservedCancellationAndShutdown(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "owned-cancellation-marker")
	if err := os.WriteFile(marker, []byte("unchanged"), 0600); err != nil {
		t.Fatal(err)
	}
	var canceled atomic.Int32
	app := &App{status: InstallStatus{Running: true}, cancel: func() {
		canceled.Add(1)
		if err := os.WriteFile(marker, []byte("canceled"), 0600); err != nil {
			t.Error(err)
		}
	}}
	assessment := NewAssessmentServer(app, &synchronizedWriter{out: &bytes.Buffer{}})
	wires := []string{
		`{"jsonrpc":"2.0","id":1,"method":"CancelInstall"}`,
		`{"jsonrpc":"2.0","id":2,"method":"Shutdown","params":{"method":"GetStatus"}}`,
		`{"jsonrpc":"2.0","id":3,"method":"CancelInstall","assessmentOnly":false,"capability":"full"}`,
		`{"jsonrpc":"2.0","id":4,"method":"GetStatus","method":"CancelInstall"}`,
	}
	for _, wire := range wires {
		_, failure := assessment.dispatch(context.Background(), assessmentWireRequest(t, wire))
		if failure == nil || failure.Code != errCodeMethodNotFound {
			t.Fatalf("mutating request not refused before action: %v; observed cancellations=%d", failure, canceled.Load())
		}
	}
	snapshot, failure := assessment.dispatch(context.Background(), assessmentWireRequest(t,
		`{"jsonrpc":"2.0","id":5,"method":"GetStatus","params":{"method":"CancelInstall","capability":"full"}}`))
	if failure != nil || snapshot.(InstallStatus).Running != true {
		t.Fatal("trusted status observation changed")
	}
	data, err := os.ReadFile(marker)
	if err != nil || string(data) != "unchanged" || canceled.Load() != 0 || assessment.shutdown {
		t.Fatal("assessment request mutated cancellation, data, or shutdown")
	}
	// Same actual backend proves authorized cancellation/shutdown are live actions.
	legacy := NewServer(app, &synchronizedWriter{out: &bytes.Buffer{}})
	if _, failure := legacy.dispatch(context.Background(), jsonrpcRequest{Method: "CancelInstall"}); failure != nil {
		t.Fatal(failure)
	}
	if _, failure := legacy.dispatch(context.Background(), jsonrpcRequest{Method: "Shutdown"}); failure != nil {
		t.Fatal(failure)
	}
	data, err = os.ReadFile(marker)
	if err != nil || string(data) != "canceled" || canceled.Load() != 1 || !legacy.shutdown {
		t.Fatal("legacy positive action did not occur")
	}
}

func TestAssessmentRPCRejectsOtherMethodsBeforeParameterAndBackendWork(t *testing.T) {
	// Linux development stubs keep exhaustive policy mutation controls safe.
	if runtime.GOOS == "windows" {
		t.Skip("exhaustive policy control uses non-Windows backend stubs")
	}
	server := NewAssessmentServer(&App{}, &synchronizedWriter{out: &bytes.Buffer{}})
	methods := append(append([]string{}, ProtocolMethods...), "GetInstallSteps", "BootInVM", "GetVMCapability", "startinstall", "GetStatus.CancelInstall", "Unknown")
	for _, method := range methods {
		if method == "GetStatus" || method == "GetLastRun" || method == "GetRecoveryVerdict" {
			continue
		}
		_, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: method, Params: json.RawMessage(`"malformed-cross-method-params"`)})
		if failure == nil || failure.Code != errCodeMethodNotFound {
			t.Errorf("%s reached parameters/backend instead of capability refusal: %v", method, failure)
		}
	}
}
