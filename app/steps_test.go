package main

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// ── One catalogue of phase names (#334) ────────────────────────────────────
//
// The words a user watches during an install live in four places: the Phase-1
// pipeline here, the step list the progress screen renders, the deployer's
// splash table, and the markers the E2E harness greps for. Nothing held them
// together and they had already drifted — five pipeline steps were missing
// from the screen's list, and one entry on the screen was never emitted, so
// it stayed grey for the entire install. To a nervous user a grey step reads
// as one that did not happen.
//
// payload/steps.tsv is the catalogue. These tests are what make it binding.

var pipelineStepRe = regexp.MustCompile(`(?m)^\s+\{"([^"]+)", \d+,`)

func pipelineSteps(t *testing.T) []string {
	t.Helper()
	data, err := os.ReadFile("app.go")
	if err != nil {
		t.Fatalf("read app.go: %v", err)
	}
	var out []string
	for _, m := range pipelineStepRe.FindAllStringSubmatch(string(data), -1) {
		out = append(out, m[1])
	}
	if len(out) < 10 {
		t.Fatalf("found only %d pipeline steps; the matcher or the pipeline changed", len(out))
	}
	return out
}

func frontendSteps(t *testing.T) []string {
	t.Helper()
	data, err := os.ReadFile("frontend/src/screens/progress.js")
	if err != nil {
		t.Fatalf("read progress.js: %v", err)
	}
	block := regexp.MustCompile(`(?s)INSTALL_STEPS = \[(.*?)\n\];`).FindStringSubmatch(string(data))
	if block == nil {
		t.Fatal("INSTALL_STEPS not found in progress.js")
	}
	var out []string
	for _, m := range regexp.MustCompile(`(?m)^\s+'(.*)',`).FindAllStringSubmatch(block[1], -1) {
		out = append(out, strings.ReplaceAll(m[1], `\'`, `'`))
	}
	return out
}

func catalogue(t *testing.T) map[string]string {
	t.Helper()
	data, err := os.ReadFile("../payload/steps.tsv")
	if err != nil {
		t.Fatalf("read steps.tsv: %v", err)
	}
	out := map[string]string{}
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) >= 2 {
			out[f[0]] = f[1]
		}
	}
	return out
}

func TestProgressScreenListsExactlyWhatThePipelineEmits(t *testing.T) {
	pipeline, frontend := pipelineSteps(t), frontendSteps(t)

	inFrontend := map[string]bool{}
	for _, s := range frontend {
		inFrontend[s] = true
	}
	for _, s := range pipeline {
		if !inFrontend[s] {
			t.Errorf("the pipeline emits %q but the progress screen never lists it — "+
				"the user never sees that step happen", s)
		}
	}
	inPipeline := map[string]bool{}
	for _, s := range pipeline {
		inPipeline[s] = true
	}
	for _, s := range frontend {
		if !inPipeline[s] {
			t.Errorf("the progress screen lists %q but nothing ever emits it — "+
				"it stays grey for the whole install, which reads as a step that failed", s)
		}
	}
	// Order matters too: the list is rendered top to bottom as a sequence.
	if len(pipeline) == len(frontend) {
		for i := range pipeline {
			if pipeline[i] != frontend[i] {
				t.Errorf("step %d differs: pipeline %q, screen %q", i, pipeline[i], frontend[i])
				break
			}
		}
	}
}

func TestEveryPipelineStepIsInTheCatalogue(t *testing.T) {
	cat := catalogue(t)
	for _, s := range pipelineSteps(t) {
		owner, ok := cat[s]
		if !ok {
			t.Errorf("pipeline step %q is not in payload/steps.tsv", s)
			continue
		}
		if owner != "installer" {
			t.Errorf("pipeline step %q is catalogued as %q, want installer", s, owner)
		}
	}
}
