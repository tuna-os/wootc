package main

import (
	"context"
	"encoding/json"
	"io"
	"reflect"
	"testing"
)

func TestServeStartupReadContracts(t *testing.T) {
	server := NewServer(NewApp(), &synchronizedWriter{out: io.Discard})
	tests := []struct {
		method   string
		expected any
	}{
		{"GetLastRun", LifecycleState{}},
		{"GetRecoveryVerdict", RecoveryVerdict{}},
		{"GetInstallSteps", []StepDefinition{}},
	}
	for _, test := range tests {
		t.Run(test.method, func(t *testing.T) {
			result, err := server.dispatch(context.Background(), jsonrpcRequest{JSONRPC: "2.0", Method: test.method})
			if err != nil {
				t.Fatalf("actual RPC refused: %+v", err)
			}
			if reflect.TypeOf(result) != reflect.TypeOf(test.expected) {
				t.Fatalf("RPC payload has wrong contract: %T", result)
			}
			bytes, marshalErr := json.Marshal(result)
			if marshalErr != nil || !json.Valid(bytes) {
				t.Fatal("RPC payload does not serialize")
			}
			if test.method == "GetInstallSteps" && !reflect.DeepEqual(result, InstallerSteps()) {
				t.Fatal("RPC catalogue differs from generated backend catalogue")
			}
		})
	}
}
