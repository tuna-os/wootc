package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"time"
)

// Diagnostics are local JSON lines on stderr, never RPC stdout. Only engine
// phase identifiers and fixed outcome codes enter this channel: subprocess
// errors, configuration, paths, session payloads and credentials never do.
// The existing journal and lifecycle records remain the recovery authority.
type migrationDiagnosticEvent struct {
	Timestamp  string `json:"timestamp"`
	AttemptID  string `json:"attemptId"`
	Phase      string `json:"phase"`
	Event      string `json:"event"`
	DurationMS int64  `json:"duration_ms"`
	ErrorCode  string `json:"error_code,omitempty"`
}

var migrationDiagnosticMu sync.Mutex

type migrationDiagnostics struct {
	now       func() time.Time
	encoder   *json.Encoder
	attemptID string
	started   time.Time
	phase     string
	phaseAt   time.Time
}

func newMigrationDiagnostics(out io.Writer, now func() time.Time) *migrationDiagnostics {
	started := now()
	d := &migrationDiagnostics{encoder: json.NewEncoder(out), now: now, started: started,
		attemptID: fmt.Sprintf("%s-%d", started.UTC().Format("20060102T150405.000000000Z"), os.Getpid())}
	d.record("install", "phase_start", started, nil)
	return d
}

func (d *migrationDiagnostics) record(phase, event string, started time.Time, err error) {
	now := d.now()
	code := ""
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		code = "cancelled"
	} else if err != nil {
		code = "operation_failed"
	}
	e := migrationDiagnosticEvent{Timestamp: now.UTC().Format(time.RFC3339Nano),
		AttemptID: d.attemptID, Phase: phase, Event: event,
		DurationMS: now.Sub(started).Milliseconds(), ErrorCode: code}
	migrationDiagnosticMu.Lock()
	defer migrationDiagnosticMu.Unlock()
	// A diagnostic sink failure must not change privileged operation outcomes.
	_ = d.encoder.Encode(e)
}

func (d *migrationDiagnostics) begin(phase string) {
	d.phase, d.phaseAt = phase, d.now()
	d.record(phase, "phase_start", d.phaseAt, nil)
}

func (d *migrationDiagnostics) complete() {
	d.record(d.phase, "phase_complete", d.phaseAt, nil)
	d.phase = ""
}

func (d *migrationDiagnostics) finish(err error) {
	event := "phase_complete"
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		event = "phase_cancelled"
	} else if err != nil {
		event = "phase_error"
	}
	if d.phase != "" {
		d.record(d.phase, event, d.phaseAt, err)
	}
	d.record("install", event, d.started, err)
}
