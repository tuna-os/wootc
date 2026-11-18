package main

import (
	"strings"
	"testing"
)

func TestHardwarePreflightRefusesBlockingFindingAndEmitsWarnings(t *testing.T) {
	report := HardwareReport{Findings: []HardwareFinding{
		{Severity: HardwareBlocking, Subject: "PCI Intel VMD", Detail: "no target storage driver claims this controller."},
		{Severity: HardwareWarning, Subject: "PCI NVIDIA", Detail: "nouveau will replace the proprietary driver."},
	}}
	var events []ProgressEvent
	err := enforceHardwareCompatibility(report, StepInstallerDownloadingYourLinuxSystem, 54, func(event ProgressEvent) {
		events = append(events, event)
	})
	if err == nil || !strings.Contains(err.Error(), "not compatible") || !strings.Contains(err.Error(), "Intel VMD") {
		t.Fatalf("blocking error = %v", err)
	}
	if len(events) != 1 || len(events[0].Warnings) != 1 || !strings.Contains(events[0].Warnings[0], "NVIDIA") {
		t.Fatalf("warning events = %+v", events)
	}
}

func TestHardwarePreflightWarningContinues(t *testing.T) {
	report := HardwareReport{Findings: []HardwareFinding{{
		Severity: HardwareWarning, Subject: "incomplete hardware check", Detail: "one image layer was unreadable.",
	}}}
	var event ProgressEvent
	if err := enforceHardwareCompatibility(report, "download", 54, func(got ProgressEvent) { event = got }); err != nil {
		t.Fatal(err)
	}
	if len(event.Warnings) != 1 || event.Step != "download" || event.Percent != 54 {
		t.Fatalf("warning event = %+v", event)
	}
}
