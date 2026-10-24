package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestHardwareAssessmentSharedCases(t *testing.T) {
	type fixtureTarget struct {
		KVersion      string      `json:"kversion"`
		Modules       []string    `json:"modules"`
		Builtin       []string    `json:"builtin"`
		Aliases       [][2]string `json:"aliases"`
		Firmware      []string    `json:"firmware"`
		LayersSkipped int         `json:"layersSkipped"`
	}
	type fixtureCase struct {
		Name         string           `json:"name"`
		Host         HostHardware     `json:"host"`
		Target       fixtureTarget    `json:"target"`
		WantSeverity HardwareSeverity `json:"wantSeverity"`
	}
	data, err := os.ReadFile("testdata/hardware/bootc-migrate-assessment-cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []fixtureCase
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	for _, testCase := range cases {
		t.Run(testCase.Name, func(t *testing.T) {
			target := TargetKernel{
				KVersion: testCase.Target.KVersion, Modules: stringSet(testCase.Target.Modules),
				Builtin: stringSet(testCase.Target.Builtin), Firmware: stringSet(testCase.Target.Firmware),
				LayersSkipped: testCase.Target.LayersSkipped,
			}
			for _, alias := range testCase.Target.Aliases {
				target.Aliases = append(target.Aliases, moduleAlias{Pattern: alias[0], Module: alias[1]})
			}
			if testCase.Host.Modules == nil {
				testCase.Host.Modules = make(map[string]HostModule)
			}
			report := assessHardware(testCase.Host, target)
			got := HardwareSeverity("none")
			for _, finding := range report.Findings {
				if severityRank(finding.Severity) > severityRank(got) {
					got = finding.Severity
				}
			}
			if got != testCase.WantSeverity {
				t.Fatalf("highest severity = %q, want %q; report: %+v", got, testCase.WantSeverity, report)
			}
			if testCase.Target.LayersSkipped > 0 && report.hasBlocking() {
				t.Fatalf("partial inventory blocked: %+v", report)
			}
		})
	}
}

func TestKernelGlobMatchVectors(t *testing.T) {
	for _, testCase := range []struct {
		pattern string
		text    string
		want    bool
	}{
		{"pci:v00008086d000015B8sv*sd*bc*sc*i*", "pci:v00008086d000015B8sv00001028sd000007A1bc02sc00i00", true},
		{"usb:v0BDAp81[0-9A]9d*", "usb:v0BDAp8179d0100", true},
		{"usb:v0BDAp81[!7]9d*", "usb:v0BDAp8179d0100", false},
		{"a?c", "abc", true},
		{"*", "anything", true},
		{"iwlwifi-*.ucode", "iwlwifi-so-a0-gf-a0-89.ucode", true},
		{"broken[", "broken[", true},
	} {
		if got := globMatch(testCase.pattern, testCase.text); got != testCase.want {
			t.Errorf("globMatch(%q, %q) = %v, want %v", testCase.pattern, testCase.text, got, testCase.want)
		}
	}
}

func TestModuleAndFirmwareParsing(t *testing.T) {
	modules := parseModuleList("kernel/drivers/net/e1000e/e1000e.ko.xz: ptp.ko\nkernel/drivers/foo-bar.ko.zst:\nnot-a-module\n")
	for _, module := range []string{"e1000e", "foo_bar"} {
		if _, ok := modules[module]; !ok {
			t.Errorf("module %q absent from %#v", module, modules)
		}
	}
	aliases := parseModuleAliases("# comment\nalias pci:v00008086d* e1000e\ngarbage\n")
	if len(aliases) != 1 || aliases[0].Module != "e1000e" {
		t.Fatalf("aliases = %#v", aliases)
	}
	builtinAliases := parseBuiltinModinfo("vmd.alias=pci:v00008086d00009A0Bsv*sd*bc01sc04i*\x00usb-core:alias=usb:v*p*d*dc*dsc*dp*ic09isc*ip*in*\x00")
	if len(builtinAliases) != 2 || builtinAliases[0].Module != "vmd" || builtinAliases[1].Module != "usb_core" {
		t.Fatalf("built-in aliases = %#v", builtinAliases)
	}
	target := TargetKernel{Firmware: stringSet([]string{"iwlwifi/a.ucode", "brcm/brcmfmac.bin"})}
	if !target.hasFirmware("iwlwifi/*.ucode.xz") || target.hasFirmware("missing/*.bin") {
		t.Fatalf("firmware matching failed for %#v", target.Firmware)
	}
}

func TestWindowsAliasFirmwareFamiliesCatchTotalFirmwareLoss(t *testing.T) {
	class := uint32(0x028000)
	host := HostHardware{Complete: true, Devices: []HostDevice{{
		Bus: "pci", ID: "Intel Wi-Fi", Modalias: "pci:v00008086d00007AF0sv00008086sd00000090bc02sc80i00", PCIClass: &class,
	}}}
	target := TargetKernel{
		KVersion: "6.17.1", Modules: stringSet([]string{"iwlwifi"}), Builtin: map[string]struct{}{},
		Aliases:  []moduleAlias{{Pattern: "pci:v00008086d00007AF0sv*sd*bc02sc80i00", Module: "iwlwifi"}},
		Firmware: map[string]struct{}{},
	}
	report := assessHardware(host, target)
	if !report.hasBlocking() {
		t.Fatalf("missing all iwlwifi firmware did not block: %+v", report)
	}
	target.Firmware["intel/iwlwifi/iwlwifi-so-a0-gf-a0-89.ucode"] = struct{}{}
	if report := assessHardware(host, target); report.hasBlocking() || len(report.Findings) != 0 {
		t.Fatalf("present iwlwifi firmware still failed: %+v", report)
	}
}

func TestKnownBuiltInHostDriverIsNotJudged(t *testing.T) {
	class := uint32(0x0c0300)
	host := HostHardware{Complete: true, Devices: []HostDevice{{
		Bus: "pci", ID: "USB root hub", Modalias: "pci:v00008086d00000000sv00000000sd00000000bc0Csc03i00",
		ModuleKnown: true, PCIClass: &class,
	}}}
	report := assessHardware(host, TargetKernel{KVersion: "6.17.1", Modules: map[string]struct{}{}, Builtin: map[string]struct{}{}, Firmware: map[string]struct{}{}})
	if report.DevicesChecked != 0 || len(report.Findings) != 0 {
		t.Fatalf("known built-in driver was judged: %+v", report)
	}
}

func TestUnclaimedNonCriticalPnPDeviceIsNotReported(t *testing.T) {
	bridgeClass := uint32(0x060000)
	host := HostHardware{Complete: true, Devices: []HostDevice{{
		Bus: "pci", ID: "host bridge", Modalias: "pci:host-bridge", PCIClass: &bridgeClass,
	}}}
	report := assessHardware(host, TargetKernel{KVersion: "6.18.0", Modules: map[string]struct{}{}, Builtin: map[string]struct{}{}, Firmware: map[string]struct{}{}})
	if len(report.Findings) != 0 {
		t.Fatalf("driverless chipset function was reported: %+v", report.Findings)
	}
}

func TestUnmatchedDevicesGroupBySeverity(t *testing.T) {
	storageClass := uint32(0x010400)
	host := HostHardware{Complete: true, Devices: []HostDevice{
		{Bus: "pci", ID: "storage", Modalias: "pci:storage", Module: "missing", PCIClass: &storageClass},
		{Bus: "usb", ID: "peripheral", Modalias: "usb:peripheral", Module: "missing"},
	}}
	report := assessHardware(host, TargetKernel{KVersion: "6.18.0", Modules: map[string]struct{}{}, Builtin: map[string]struct{}{}, Firmware: map[string]struct{}{}})
	if len(report.Findings) != 2 {
		t.Fatalf("findings were grouped across severity: %+v", report.Findings)
	}
	if report.Findings[0].Severity != HardwareBlocking || report.Findings[1].Severity != HardwareWarning {
		t.Fatalf("finding severities = %+v", report.Findings)
	}
}

func TestGroupedDeviceSubjectKeepsTheExplanationVisible(t *testing.T) {
	host := HostHardware{Complete: true}
	for _, id := range []string{"six", "five", "four", "three", "two", "one"} {
		host.Devices = append(host.Devices, HostDevice{Bus: "usb", ID: id, Modalias: "usb:" + id, Module: "missing"})
	}
	report := assessHardware(host, TargetKernel{KVersion: "6.18.0", Modules: map[string]struct{}{}, Builtin: map[string]struct{}{}, Firmware: map[string]struct{}{}})
	if len(report.Findings) != 1 || !strings.Contains(report.Findings[0].Subject, "and 2 more") {
		t.Fatalf("grouped finding = %+v", report.Findings)
	}
	if warnings := report.warningMessages(); len(warnings) != 1 || !strings.Contains(warnings[0], "uses driver missing") {
		t.Fatalf("warning lost its explanation: %q", warnings)
	}
}

func TestHardwareMessagesFitNativeProtocolLimits(t *testing.T) {
	report := HardwareReport{}
	for range 40 {
		report.Findings = append(report.Findings, HardwareFinding{
			Severity: HardwareWarning,
			Subject:  "device",
			Detail:   strings.Repeat("界", maxHardwareMessageRunes+100),
		})
	}
	messages := report.warningMessages()
	if len(messages) != maxHardwareWarningCount {
		t.Fatalf("warning count = %d", len(messages))
	}
	for _, message := range messages {
		if len([]rune(message)) > maxHardwareMessageRunes {
			t.Fatalf("warning has %d runes", len([]rune(message)))
		}
	}

	report.Findings = []HardwareFinding{{Severity: HardwareBlocking, Subject: "device", Detail: strings.Repeat("界", 5000)}}
	if errorRunes := len([]rune(report.blockingError().Error())); errorRunes >= 4096 {
		t.Fatalf("blocking error has %d runes", errorRunes)
	}
}

func stringSet(values []string) map[string]struct{} {
	set := make(map[string]struct{}, len(values))
	for _, value := range values {
		set[value] = struct{}{}
	}
	return set
}
