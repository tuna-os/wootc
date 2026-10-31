package main

import (
	"context"
	"errors"
	"reflect"
	"testing"
)

type recordingInstallPlatform struct {
	prepared  bool
	released  bool
	pipeline  []installPipelineStep
	failure   error
	states    []string
	disarmCnt int
}

func (p *recordingInstallPlatform) prepare(string) (func(), error) {
	p.prepared = true
	return func() { p.released = true }, nil
}

func (p *recordingInstallPlatform) steps(context.Context, InstallConfig, func(ProgressEvent)) []installPipelineStep {
	steps := make([]installPipelineStep, len(p.pipeline))
	copy(steps, p.pipeline)
	for i := range steps {
		step := steps[i]
		steps[i].fn = func() error {
			p.run = append(p.run, step.name)
			return p.failure
		}
	}
	return steps
}

func (p *recordingInstallPlatform) newJournal(InstallConfig) *installJournalRecorder { return nil }

func (p *recordingInstallPlatform) writeState(state, phase, errMsg string) {
	p.states = append(p.states, state+":"+phase+":"+errMsg)
}

func (p *recordingInstallPlatform) disarmOneShot() { p.disarmCnt++ }

func TestInstallEngineDelegatesOrderedWorkAndReleasesPlatform(t *testing.T) {
	platform := &recordingInstallPlatform{pipeline: []installPipelineStep{
		{name: "prepare"},
		{name: "commit"},
	}}
	engine := &installEngine{platform: platform}

	if err := engine.Run(context.Background(), InstallConfig{}, func(ProgressEvent) {}); err != nil {
		t.Fatalf("Run() error = %v", err)
	}
	if !platform.prepared || !platform.released {
		t.Fatalf("platform lifecycle = prepared %v, released %v", platform.prepared, platform.released)
	}
	if want := []string{"prepare", "commit"}; !reflect.DeepEqual(platform.run, want) {
		t.Fatalf("step order = %v, want %v", platform.run, want)
	}
	if want := []string{"armed::"}; !reflect.DeepEqual(platform.states, want) {
		t.Fatalf("terminal state = %v, want %v", platform.states, want)
	}
	if platform.disarmCnt != 0 {
		t.Fatalf("disarm count = %d, want 0", platform.disarmCnt)
	}
}

func TestInstallEngineCancelsBeforeFirstStep(t *testing.T) {
	platform := &recordingInstallPlatform{pipeline: []installPipelineStep{{name: "never"}}}
	engine := &installEngine{platform: platform}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	err := engine.Run(ctx, InstallConfig{}, func(ProgressEvent) {})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Run() error = %v, want context.Canceled", err)
	}
	if !platform.prepared || !platform.released {
		t.Fatalf("platform lifecycle = prepared %v, released %v", platform.prepared, platform.released)
	}
	if len(platform.run) != 0 {
		t.Fatalf("ran cancelled steps = %v", platform.run)
	}
	if want := []string{"staged:cancelled:"}; !reflect.DeepEqual(platform.states, want) {
		t.Fatalf("cancel state = %v, want %v", platform.states, want)
	}
}

func TestInstallEngineRecordsStepFailure(t *testing.T) {
	expected := errors.New("platform failed")
	platform := &recordingInstallPlatform{
		pipeline: []installPipelineStep{{name: "failure"}},
		failure:  expected,
	}
	engine := &installEngine{platform: platform}

	err := engine.Run(context.Background(), InstallConfig{}, func(ProgressEvent) {})
	if !errors.Is(err, expected) {
		t.Fatalf("Run() error = %v, want %v", err, expected)
	}
	if !platform.prepared || !platform.released {
		t.Fatalf("platform lifecycle = prepared %v, released %v", platform.prepared, platform.released)
	}
	if want := []string{"failed:failure:platform failed"}; !reflect.DeepEqual(platform.states, want) {
		t.Fatalf("failure state = %v, want %v", platform.states, want)
	}
}
