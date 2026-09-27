package main

import (
	"context"
	"testing"
)

func TestProgressCatalogueMatchesActualPipelineOrder(t *testing.T) {
	pipeline := installPipelineSteps(context.Background(), InstallConfig{}, func(ProgressEvent) {})
	catalogue := (&App{}).GetInstallSteps()
	if len(pipeline) != len(catalogue) {
		t.Fatalf("pipeline has %d steps, backend exposes %d", len(pipeline), len(catalogue))
	}
	for i, step := range pipeline {
		if step.name != catalogue[i].ID || catalogue[i].Owner != "installer" {
			t.Fatalf("pipeline step %d %q differs from backend %+v", i, step.name, catalogue[i])
		}
		event := installStepProgress(step.name, step.percent)
		if event.PhaseID != catalogue[i].ID || event.Message != catalogue[i].Label+"…" {
			t.Fatalf("progress did not consume catalogue: %+v", event)
		}
	}
}

func TestProgressLabelIsIndependentOfStableID(t *testing.T) {
	// This catalogue entry has a display label different from its stable ID.
	id := StepDeployerFisherman
	label, ok := StepLabel(id)
	if !ok || label == id {
		t.Fatal("test requires a distinct catalogue label")
	}
	event := installStepProgress(id, 42)
	if event.Step != id || event.PhaseID != id || event.Message != label+"…" {
		t.Fatalf("display label replaced identity or was ignored: %+v", event)
	}
	title, _ := friendlySplashMessageForPhase(id)
	if title != label {
		t.Fatalf("recovery ignored generated display label: %q, want %q", title, label)
	}
}
