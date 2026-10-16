package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestNativeConfigurationRPCRequiresTrustedCapabilityAndNoParameters(t *testing.T) {
	root := t.TempDir()
	marker := filepath.Join(root, "owned-marker")
	if err := os.WriteFile(marker, []byte("unchanged"), 0600); err != nil {
		t.Fatal(err)
	}
	calls, cancellations := 0, 0
	app := &App{cancel: func() { cancellations++; _ = os.WriteFile(marker, []byte("mutated"), 0600) }}
	writer := &synchronizedWriter{out: &bytes.Buffer{}}
	read := func(ctx context.Context) (NativeConfigurationSnapshot, error) {
		calls++
		return readNativeConfiguration(ctx, []string{root}, "", false, func(string) error { return nil })
	}
	server := newConfigurationAssessmentServer(app, writer, read)
	for _, request := range []jsonrpcRequest{{Method: "StartInstall"}, {Method: "CancelInstall"}, {Method: "Shutdown"}, {Method: "GetImages"}, {Method: "GetNativeConfiguration", Params: []byte(`{"installAuthorized":true}`)}} {
		if _, failure := server.dispatch(context.Background(), request); failure == nil {
			t.Fatal("untrusted request accepted")
		}
	}
	if calls != 0 || cancellations != 0 || server.shutdown {
		t.Fatal("refusal performed backend work")
	}
	result, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: "GetNativeConfiguration"})
	if failure != nil || result.(NativeConfigurationSnapshot).InstallAuthorized || calls != 1 {
		t.Fatal("configuration read did not preserve assessment contract")
	}
	for _, other := range []*Server{NewAssessmentServer(app, writer), NewServer(app, writer)} {
		if _, failure := other.dispatch(context.Background(), jsonrpcRequest{Method: "GetNativeConfiguration"}); failure == nil || failure.Code != errCodeMethodNotFound {
			t.Fatal("client upgraded another server capability")
		}
	}
	server.startupValidate = func(context.Context) error { return fmt.Errorf("private-path-and-secret") }
	if _, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: "GetNativeConfiguration"}); failure == nil || failure.Message != "native startup observation refused" || calls != 1 {
		t.Fatal("changed startup reached configuration reader")
	}
	data, err := os.ReadFile(marker)
	if err != nil || string(data) != "unchanged" {
		t.Fatal("configuration assessment mutated private fixture")
	}
}

type nativeConfigurationDiagnosticFixtureError struct{}

func (*nativeConfigurationDiagnosticFixtureError) Error() string { return "private-secret-and-path" }
func (*nativeConfigurationDiagnosticFixtureError) nativeConfigurationDiagnostic() any {
	return map[string]any{"schemaVersion": 1, "kind": "storage-observation"}
}
func TestNativeConfigurationRPCFailureKeepsFixedDiagnostic(t *testing.T) {
	server := newConfigurationAssessmentServer(&App{}, &synchronizedWriter{out: &bytes.Buffer{}}, func(context.Context) (NativeConfigurationSnapshot, error) {
		return NativeConfigurationSnapshot{}, &nativeConfigurationDiagnosticFixtureError{}
	})
	result, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: "GetNativeConfiguration"})
	if result != nil || failure == nil || failure.Message != "native configuration observation refused" || failure.Data == nil {
		t.Fatal("current failed request lost bounded diagnostic")
	}
	encoded, err := json.Marshal(failure)
	if err != nil || bytes.Contains(encoded, []byte("private")) {
		t.Fatal("error text escaped")
	}
	server.configurationRead = func(context.Context) (NativeConfigurationSnapshot, error) {
		return NativeConfigurationSnapshot{}, fmt.Errorf("private-secret")
	}
	_, failure = server.dispatch(context.Background(), jsonrpcRequest{Method: "GetNativeConfiguration"})
	if failure == nil || failure.Data != nil {
		t.Fatal("unknown failure gained diagnostic authority")
	}
}

func TestNativeConfigurationTimingAttributesWholeObservedCall(t *testing.T) {
	timing := newNativeConfigurationTiming()
	time.Sleep(2 * time.Millisecond)
	timing.mark("initial-selection")
	time.Sleep(2 * time.Millisecond)
	timing.mark("storage-first-query")
	time.Sleep(2 * time.Millisecond)
	phase, total, durations := timing.finish()
	if phase != "storage-first-query" || total < 6 || durations["root-enumeration"] < 2 || durations["initial-selection"] < 2 || durations["storage-first-query"] < 2 {
		t.Fatal("whole call lost measured earlier phases")
	}
	var sum int64
	for _, duration := range durations {
		if duration < 0 {
			t.Fatal("negative monotonic duration")
		}
		sum += duration
	}
	if sum > total || total-sum > 256 {
		t.Fatal("observed phase timing inconsistent")
	}
}
