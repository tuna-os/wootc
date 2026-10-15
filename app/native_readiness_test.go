package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
)

func TestNativeAssessmentReadyAfterPreparation(t *testing.T) {
	var output bytes.Buffer
	prepared := false
	hello := nativeHandshake{Kind: "hello", ProtocolVersion: 1, Session: strings.Repeat("a", 32), BuildID: strings.Repeat("b", 40), BrandID: "wootc"}
	err := prepareNativeAssessment(context.Background(), hello, &output, func(context.Context) (bool, error) {
		if strings.Contains(output.String(), `"ready"`) {
			return false, errors.New("ready before selection")
		}
		return true, nil
	}, func(found bool) error {
		if !found || strings.Contains(output.String(), `"ready"`) {
			t.Fatal("invalid application preparation")
		}
		prepared = true
		return nil
	}, func() error { return nil })
	if err != nil || !prepared || !strings.Contains(output.String(), `"kind":"ready"`) {
		t.Fatalf("preparation failed: %v", err)
	}
	if lines := strings.Count(output.String(), "\n"); lines != 7 {
		t.Fatalf("unbounded/wrong phase count: %d", lines)
	}
}

func TestNativeAssessmentBlockedAndFailedSelectionNeverReady(t *testing.T) {
	for _, blocked := range []bool{false, true} {
		t.Run(map[bool]string{false: "refused", true: "blocked"}[blocked], func(t *testing.T) {
			var output bytes.Buffer
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			release := make(chan struct{})
			defer close(release)
			calls := 0
			err := prepareNativeAssessment(ctx, nativeHandshake{}, &output, func(context.Context) (bool, error) {
				if blocked {
					cancel()
					<-release
					return true, nil
				}
				return false, errors.New("public-secret-must-not-cross-pipe")
			}, func(bool) error { calls++; return nil }, func() error { return nil })
			if err == nil || calls != 0 || strings.Contains(output.String(), `"ready"`) || strings.Contains(output.String(), "public-secret") || !strings.Contains(output.String(), `"outcome":"failed"`) {
				t.Fatalf("selection escaped readiness gate: %v %s", err, output.String())
			}
		})
	}
}

func TestNativeAssessmentDriftRefusesAllStartupReads(t *testing.T) {
	app := NewApp()
	app.setStatus(InstallStatus{Existing: false})
	server := NewAssessmentServer(app, &synchronizedWriter{out: &bytes.Buffer{}})
	server.strictStartup = true
	calls := 0
	server.startupValidate = func(context.Context) error { calls++; return errors.New("public-secret-path-must-not-cross-pipe") }
	for _, method := range []string{"GetStatus", "GetLastRun", "GetRecoveryVerdict"} {
		result, err := server.dispatch(context.Background(), jsonrpcRequest{JSONRPC: "2.0", Method: method})
		if result != nil || err == nil || err.Message != "native startup observation refused" {
			t.Fatalf("%s guessed observation after drift: %v %+v", method, result, err)
		}
	}
	if calls != 3 {
		t.Fatalf("startup reads bypassed revalidation: %d", calls)
	}
}
