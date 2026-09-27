package main

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestGetInstallStepsDefensiveCatalogue(t *testing.T) {
	a := &App{}
	steps := a.GetInstallSteps()
	if len(steps) == 0 {
		t.Fatal("empty installer catalogue")
	}
	first := steps[0]
	steps[0].ID = "caller-mutated"
	steps[0].Label = "caller-mutated"
	if a.GetInstallSteps()[0] != first {
		t.Fatal("caller mutated shared catalogue")
	}
	for _, step := range a.GetInstallSteps() {
		if step.Owner != "installer" {
			t.Fatalf("non-installer entry: %+v", step)
		}
		data, err := json.Marshal(step)
		if err != nil {
			t.Fatal(err)
		}
		var fields map[string]string
		if err := json.Unmarshal(data, &fields); err != nil {
			t.Fatal(err)
		}
		if len(fields) != 3 || fields["id"] != step.ID || fields["owner"] != step.Owner || fields["label"] != step.Label {
			t.Fatalf("incorrect transport fields: %s", data)
		}
	}
}

func TestRecoveryObservedPhaseSeparateFromVerdict(t *testing.T) {
	phase := StepDeployerFisherman
	verdict := EvaluateRecovery(ArmedState{}, true, LifecycleState{State: StateFailed, Phase: "legacy diagnostic", PhaseID: phase}, t.TempDir())
	if verdict.PhaseID != phase || verdict.Phase != "legacy diagnostic" || verdict.Verdict != VerdictFailed {
		t.Fatalf("lost domain separation: %+v", verdict)
	}
	title, _ := friendlySplashMessageForPhase(phase)
	if verdict.Title != title {
		t.Fatalf("recovery did not consume explicit observed phase: %+v", verdict)
	}
	for _, state := range []string{StateDeploying, StateDeployed, StateHealthy, VerdictNeverBooted, "cancelled", "unknown-phase"} {
		if observedStepID(state) != "" {
			t.Fatalf("non-step %q became observed step", state)
		}
		v := EvaluateRecovery(ArmedState{}, true, LifecycleState{State: StateFailed, Phase: state, PhaseID: state}, t.TempDir())
		if v.PhaseID != "" {
			t.Fatalf("invented observed phase for %q", state)
		}
	}
	legacy := EvaluateRecovery(ArmedState{}, true, LifecycleState{State: StateFailed, Phase: phase}, t.TempDir())
	if legacy.PhaseID != phase {
		t.Fatal("legacy observed deployer phase was lost")
	}
}

func TestGetInstallStepsRPC(t *testing.T) {
	h := newPipeHarness(t)
	result, rpcErr := h.call(t, "GetInstallSteps", nil, 334)
	if rpcErr != nil {
		t.Fatalf("RPC failed: %+v", rpcErr)
	}
	var got []StepDefinition
	if err := json.Unmarshal(result, &got); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, (&App{}).GetInstallSteps()) {
		t.Fatalf("RPC catalogue mismatch: %+v", got)
	}
}
