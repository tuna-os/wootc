package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
	"time"
)

func diagnosticEvents(t *testing.T, data []byte) []migrationDiagnosticEvent {
	t.Helper()
	decoder := json.NewDecoder(bytes.NewReader(data))
	var events []migrationDiagnosticEvent
	for {
		var event migrationDiagnosticEvent
		err := decoder.Decode(&event)
		if err == io.EOF {
			return events
		}
		if err != nil {
			t.Fatal(err)
		}
		events = append(events, event)
	}
}

func TestMigrationDiagnosticsTimelineAndDurations(t *testing.T) {
	var sink bytes.Buffer
	clock := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	d := newMigrationDiagnostics(&sink, func() time.Time { return clock })
	d.begin("preflight")
	clock = clock.Add(1500 * time.Millisecond)
	d.complete()
	d.begin("disk_provision")
	clock = clock.Add(2500 * time.Millisecond)
	d.complete()
	d.finish(nil)
	events := diagnosticEvents(t, sink.Bytes())
	if len(events) != 6 {
		t.Fatalf("events = %+v", events)
	}
	if events[2].Phase != "preflight" || events[2].Event != "phase_complete" || events[2].DurationMS != 1500 {
		t.Fatalf("preflight completion = %+v", events[2])
	}
	if events[4].DurationMS != 2500 || events[5].Phase != "install" || events[5].DurationMS != 4000 {
		t.Fatalf("terminal durations = %+v", events[4:])
	}
	for _, event := range events {
		if event.AttemptID == "" || event.AttemptID != events[0].AttemptID || event.Timestamp == "" {
			t.Fatalf("uncorrelated event = %+v", event)
		}
	}
}

func TestMigrationDiagnosticsNeverIncludeRawFailureCredentials(t *testing.T) {
	for _, test := range []struct {
		err   error
		event string
		code  string
	}{
		{errors.New("password=secret-key token=private-cookie"), "phase_error", "operation_failed"},
		{context.Canceled, "phase_cancelled", "cancelled"},
		{context.DeadlineExceeded, "phase_cancelled", "cancelled"},
	} {
		var sink bytes.Buffer
		d := newMigrationDiagnostics(&sink, time.Now)
		d.begin("vault")
		d.finish(test.err)
		if strings.Contains(sink.String(), "secret-key") || strings.Contains(sink.String(), "private-cookie") {
			t.Fatal("raw error escaped to diagnostics")
		}
		events := diagnosticEvents(t, sink.Bytes())
		if len(events) != 4 || events[2].Event != test.event || events[3].ErrorCode != test.code {
			t.Fatalf("failure events = %+v", events)
		}
	}
}

type rejectingDiagnosticWriter struct{}

func (rejectingDiagnosticWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestMigrationDiagnosticsSinkFailureDoesNotChangeOutcome(t *testing.T) {
	d := newMigrationDiagnostics(rejectingDiagnosticWriter{}, time.Now)
	d.begin("preflight")
	d.complete()
	d.finish(nil)
}
