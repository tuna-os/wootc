package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
)

// Exactly three source-owned phases precede ready. Records carry no paths,
// exception messages, or caller-selected phase text.
type nativeStartupPhase struct {
	nativeHandshake
	Phase   string `json:"phase"`
	Outcome string `json:"outcome"`
}

// selectInstall must be read-only: a deadline may return while an OS read is
// still blocked, and must never abandon ACL repair or installation writes.
func prepareNativeAssessment(ctx context.Context, hello nativeHandshake, out io.Writer, selectInstall func(context.Context) (bool, error), prepare func(bool) error, prepareDispatcher func() error) error {
	emit := func(phase, outcome string) error {
		record := nativeStartupPhase{nativeHandshake: hello, Phase: phase, Outcome: outcome}
		record.Kind = "startup"
		return json.NewEncoder(out).Encode(record)
	}
	if err := emit("selection", "begin"); err != nil {
		return err
	}
	type result struct {
		found bool
		err   error
	}
	selected := make(chan result, 1)
	go func() { found, err := selectInstall(ctx); selected <- result{found, err} }()
	var found bool
	select {
	case <-ctx.Done():
		_ = emit("selection", "failed")
		return fmt.Errorf("native startup selection deadline")
	case observed := <-selected:
		if observed.err != nil {
			_ = emit("selection", "failed")
			return fmt.Errorf("native startup selection refused")
		}
		found = observed.found
	}
	if ctx.Err() != nil {
		_ = emit("selection", "failed")
		return fmt.Errorf("native startup selection deadline")
	}
	if err := emit("selection", "complete"); err != nil {
		return err
	}
	if err := emit("application", "begin"); err != nil {
		return err
	}
	if err := prepare(found); err != nil {
		_ = emit("application", "failed")
		return fmt.Errorf("native startup application refused")
	}
	if err := emit("application", "complete"); err != nil {
		return err
	}
	if err := emit("dispatcher", "begin"); err != nil {
		return err
	}
	if err := prepareDispatcher(); err != nil {
		_ = emit("dispatcher", "failed")
		return fmt.Errorf("native startup dispatcher refused")
	}
	if err := emit("dispatcher", "complete"); err != nil {
		return err
	}
	if ctx.Err() != nil {
		return fmt.Errorf("native startup preparation deadline")
	}
	hello.Kind = "ready"
	return json.NewEncoder(out).Encode(hello)
}
