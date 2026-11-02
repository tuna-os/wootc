package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestHardwareGlobUpstreamFixtures(t *testing.T) {
	data, err := os.ReadFile("data/hardware-fixtures.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixtures struct {
		Glob [][]json.RawMessage `json:"glob"`
	}
	if err := json.Unmarshal(data, &fixtures); err != nil {
		t.Fatal(err)
	}
	for _, row := range fixtures.Glob {
		var pattern, text string
		var want bool
		if len(row) != 3 {
			t.Fatal("bad fixture")
		}
		if err := json.Unmarshal(row[0], &pattern); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(row[1], &text); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(row[2], &want); err != nil {
			t.Fatal(err)
		}
		if got := hardwareGlob(pattern, text); got != want {
			t.Errorf("%q against %q = %v, want %v", pattern, text, got, want)
		}
	}
}

func hardwareTestKernel() hardwareKernel {
	return hardwareKernel{version: "6.17.test", modules: map[string]string{}, builtin: map[string]bool{}, firmware: map[string]bool{}, moduleFirmware: map[string][]string{}, firmwareUnknown: map[string]bool{}}
}

func TestHardwarePnPPCIIdentity(t *testing.T) {
	got := hardwareFromPnP(hardwarePnPDevice{ID: `PCI\VEN_8086&DEV_A0F0&SUBSYS_00748086\3`, HardwareIDs: []string{`PCI\VEN_8086&DEV_A0F0&SUBSYS_00748086&REV_20`}, CompatibleIDs: []string{`PCI\CC_0280`}})
	if got.Modalias != "pci:v00008086d0000A0F0sv00008086sd00000074bc02sc80i00" || got.Uncertain || got.Class != 0x028000 {
		t.Fatalf("PCI mapping = %+v", got)
	}
	partial := hardwareFromPnP(hardwarePnPDevice{ID: `PCI\VEN_8086&DEV_A0F0`, HardwareIDs: []string{`PCI\VEN_8086&DEV_A0F0`}})
	if !partial.Uncertain {
		t.Fatal("missing PnP fields were invented")
	}
	usb := hardwareFromPnP(hardwarePnPDevice{ID: `USB\VID_0BDA&PID_8179`, HardwareIDs: []string{`USB\VID_0BDA&PID_8179&REV_0200`}, CompatibleIDs: []string{`USB\Class_FF&SubClass_FF&Prot_FF`}})
	if !usb.Uncertain || !strings.HasPrefix(usb.Modalias, "usb:v0BDAp8179d0200") {
		t.Fatalf("USB mapping = %+v", usb)
	}
}

func TestHardwareCriticalDriverRefusalAndPartialEvidence(t *testing.T) {
	for _, class := range []uint32{0x010400, 0x028000, 0x030000, 0x0c0330, 0x0d0000} {
		k := hardwareTestKernel()
		dev := hardwareDevice{ID: "critical", Modalias: "pci:v00008086d00001234sv00000000sd00000000bc01sc04i00", Class: class}
		r := assessHardware([]hardwareDevice{dev}, k)
		if len(r.Findings) != 1 || r.Findings[0].Severity != "blocking" {
			t.Fatalf("class %06x report = %+v", class, r)
		}
		k.partial = true
		r = assessHardware([]hardwareDevice{dev}, k)
		for _, f := range r.Findings {
			if f.Severity == "blocking" {
				t.Fatalf("partial inventory blocked: %+v", r)
			}
		}
	}
}

func TestHardwareNvidiaFramebufferAndFirmwareWarnings(t *testing.T) {
	k := hardwareTestKernel()
	dev := hardwareDevice{ID: "NVIDIA", Modalias: "pci:v000010DEd00002484sv00001458sd00004037bc03sc00i00", Class: 0x030000, NVIDIA: true}
	k.modules["nouveau"] = "nouveau.ko"
	k.aliases = []hardwareAlias{{"pci:v000010DEd*sv*sd*bc03sc*i*", "nouveau"}}
	k.moduleFirmware["nouveau"] = []string{"nvidia/gsp.bin"}
	r := assessHardware([]hardwareDevice{dev}, k)
	if len(r.Findings) != 2 {
		t.Fatalf("expected NVIDIA fallback and missing firmware warnings: %+v", r)
	}
	for _, f := range r.Findings {
		if f.Severity != "warning" {
			t.Fatalf("unproven Windows firmware absence blocks: %+v", r)
		}
	}
	k.firmware["nvidia/gsp.bin"] = true
	if r := assessHardware([]hardwareDevice{dev}, k); len(r.Findings) != 1 {
		t.Fatalf("present firmware warning: %+v", r)
	}
	delete(k.modules, "nouveau")
	k.builtin["simpledrm"] = true
	r = assessHardware([]hardwareDevice{dev}, k)
	if len(r.Findings) != 1 || r.Findings[0].Severity != "warning" || !strings.Contains(r.Findings[0].Detail, "framebuffer") {
		t.Fatalf("firmware framebuffer = %+v", r)
	}
}

func TestHardwareUnknownDoesNotClaimSupport(t *testing.T) {
	k := hardwareTestKernel()
	for _, devices := range [][]hardwareDevice{nil, {{ID: "USB", Uncertain: true}}} {
		r := assessHardware(devices, k)
		if len(r.Findings) == 0 || r.DevicesChecked != 0 {
			t.Fatalf("unknown claimed check: %+v", r)
		}
	}
}

func TestHardwareFirmwareNormalizationAndGlob(t *testing.T) {
	k := hardwareTestKernel()
	k.firmware["iwlwifi-cc-a0-77.ucode"] = true
	if !k.hasFirmware("./iwlwifi-cc-a0-*.ucode.xz") || k.hasFirmware("nvidia/gsp.bin") {
		t.Fatal("compressed firmware normalization/glob mismatch")
	}
	if hardwareModuleName("snd-hda-intel") != "snd_hda_intel" {
		t.Fatal("module normalization")
	}
}

func TestHardwareGateRecordsWarningsAndRefusesBlocking(t *testing.T) {
	r := hardwareReport{Image: "example:stable", Findings: []hardwareFinding{{"warning", "partial", "not a pass"}, {"blocking", "storage", "no driver"}}}
	var messages []string
	name := filepath.Join(t.TempDir(), "report.json")
	err := finishHardwarePreflight(r, name, func(s string) { messages = append(messages, s) })
	if err == nil || !strings.Contains(err.Error(), "before disk or boot changes") || len(messages) != 2 || !strings.HasPrefix(messages[0], "Hardware compatibility WARNING") {
		t.Fatalf("gate: %v %v", err, messages)
	}
	data, err := os.ReadFile(name)
	if err != nil {
		t.Fatal(err)
	}
	var got hardwareReport
	if err := json.Unmarshal(data, &got); err != nil || got.Image != r.Image {
		t.Fatalf("report persistence: %v %+v", err, got)
	}
	r.Findings = r.Findings[:1]
	if err := finishHardwarePreflight(r, "", func(string) {}); err != nil {
		t.Fatalf("warning blocked: %v", err)
	}
}
