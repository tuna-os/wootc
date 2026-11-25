package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// The E2E seeds these DisplayNames under HKCU\...\Uninstall and asserts the
// Flatpaks land in the target. If the table loses one of them, the release
// gate would install nothing and this is the first place that says so.
func TestEmbeddedAppFlatpaksTableCarriesTheSeededApps(t *testing.T) {
	table, err := embeddedAppFlatpaks()
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"gimp": "org.gimp.GIMP", "inkscape": "org.inkscape.Inkscape", "audacity": "org.audacityteam.Audacity"}
	for _, app := range table.Apps {
		if id, ok := want[app.Key]; ok {
			if app.Flatpak != id {
				t.Errorf("%s maps to %s, want %s", app.Key, app.Flatpak, id)
			}
			delete(want, app.Key)
		}
	}
	if len(want) != 0 {
		t.Fatalf("app-flatpaks.json lacks %v", want)
	}
}

// Every Windows 11 machine lists Microsoft Edge in HKLM\...\Uninstall. A
// match for it would check a browser install by default for every person.
func TestEmbeddedAppFlatpaksNeverMatchesEdge(t *testing.T) {
	table, err := embeddedAppFlatpaks()
	if err != nil {
		t.Fatal(err)
	}
	if got := detectAppsFromDisplayNames(table, []string{"Microsoft Edge", "Microsoft Edge WebView2 Runtime", "Microsoft Edge Update"}); len(got) != 0 {
		t.Fatalf("an Edge entry offers %+v", got)
	}
}

func TestParseAppFlatpaksRefusesAMisreadableTable(t *testing.T) {
	valid := `{"schemaVersion":1,"apps":[{"key":"gimp","name":"GIMP","flatpak":"org.gimp.GIMP","match":["gimp"]}]}`
	if _, err := parseAppFlatpaks([]byte(valid)); err != nil {
		t.Fatalf("valid table refused: %v", err)
	}
	for name, table := range map[string]string{
		"schema":         strings.Replace(valid, `"schemaVersion":1`, `"schemaVersion":2`, 1),
		"empty":          `{"schemaVersion":1,"apps":[]}`,
		"unknown-field":  strings.Replace(valid, `"name":"GIMP"`, `"name":"GIMP","flathub":true`, 1),
		"not-an-id":      strings.Replace(valid, `org.gimp.GIMP`, `gimp`, 1),
		"uppercase":      strings.Replace(valid, `["gimp"]`, `["GIMP"]`, 1),
		"blank-match":    strings.Replace(valid, `["gimp"]`, `[" "]`, 1),
		"no-match":       strings.Replace(valid, `["gimp"]`, `[]`, 1),
		"no-name":        strings.Replace(valid, `"name":"GIMP"`, `"name":""`, 1),
		"duplicate-key":  strings.Replace(valid, `]}`, `,{"key":"gimp","name":"GIMP","flatpak":"org.gimp.GIMP","match":["gimp"]}]}`, 1),
		"trailing-array": `[` + valid + `]`,
	} {
		if _, err := parseAppFlatpaks([]byte(table)); err == nil {
			t.Errorf("%s: accepted %s", name, table)
		}
	}
}

func TestDetectAppsFromDisplayNames(t *testing.T) {
	table, err := embeddedAppFlatpaks()
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name  string
		names []string
		want  []DetectedApp
	}{
		{"seeded", []string{"GIMP 2.10.36", "Inkscape 1.4.2", "Audacity 3.7.1"}, []DetectedApp{
			{Flatpak: "org.gimp.GIMP", Name: "GIMP", DisplayName: "GIMP 2.10.36"},
			{Flatpak: "org.inkscape.Inkscape", Name: "Inkscape", DisplayName: "Inkscape 1.4.2"},
			{Flatpak: "org.audacityteam.Audacity", Name: "Audacity", DisplayName: "Audacity 3.7.1"},
		}},
		{"case-and-space", []string{"  gimp 3.0.4  "}, []DetectedApp{{Flatpak: "org.gimp.GIMP", Name: "GIMP", DisplayName: "gimp 3.0.4"}}},
		{"registry-order", []string{"Audacity 3.7.1", "GIMP 2.10.36"}, []DetectedApp{
			{Flatpak: "org.audacityteam.Audacity", Name: "Audacity", DisplayName: "Audacity 3.7.1"},
			{Flatpak: "org.gimp.GIMP", Name: "GIMP", DisplayName: "GIMP 2.10.36"},
		}},
		// HKLM and HKCU can both list one program; one Flatpak, first name kept.
		{"once-per-flatpak", []string{"GIMP 2.10.36", "GIMP 2.10.38 (user)"}, []DetectedApp{{Flatpak: "org.gimp.GIMP", Name: "GIMP", DisplayName: "GIMP 2.10.36"}}},
		{"two-matches-one-flatpak", []string{"Adobe Acrobat Reader DC", "Adobe Reader XI"}, []DetectedApp{{Flatpak: "org.gnome.Evince", Name: "Evince", DisplayName: "Adobe Acrobat Reader DC"}}},
		{"non-matching", []string{"Microsoft Office Professional Plus 2021", "Logitech Options", "Windows Subsystem for Linux", "", "   "}, []DetectedApp{}},
		{"none", nil, []DetectedApp{}},
	} {
		t.Run(test.name, func(t *testing.T) {
			got := detectAppsFromDisplayNames(table, test.names)
			if got == nil || !reflect.DeepEqual(got, test.want) {
				t.Fatalf("detected %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestValidateFlatpakSelection(t *testing.T) {
	detected := []DetectedApp{{Flatpak: "org.gimp.GIMP"}, {Flatpak: "org.inkscape.Inkscape"}, {Flatpak: "org.audacityteam.Audacity"}}
	for _, accepted := range [][]string{nil, {}, {"org.inkscape.Inkscape"}, {"org.audacityteam.Audacity", "org.gimp.GIMP", "org.inkscape.Inkscape"}} {
		if err := validateFlatpakSelection(accepted, detected); err != nil {
			t.Errorf("refused %v: %v", accepted, err)
		}
	}
	tooMany := make([]string, maxFlatpakSelection+1)
	for index := range tooMany {
		tooMany[index] = "org.example.App" + strings.Repeat("x", index)
	}
	for name, test := range map[string]struct {
		selected []string
		detected []DetectedApp
		says     string
	}{
		"undetected":        {[]string{"org.kde.krita"}, detected, "org.kde.krita"},
		"nothing-detected":  {[]string{"org.gimp.GIMP"}, nil, "org.gimp.GIMP"},
		"duplicate":         {[]string{"org.gimp.GIMP", "org.gimp.GIMP"}, detected, "more than once"},
		"not-an-id":         {[]string{"gimp"}, detected, "not a Flatpak ID"},
		"command-injection": {[]string{"org.gimp.GIMP; rm -rf /"}, detected, "not a Flatpak ID"},
		"too-many":          {tooMany, detected, "at most"},
	} {
		err := validateFlatpakSelection(test.selected, test.detected)
		if err == nil || !strings.Contains(err.Error(), test.says) {
			t.Errorf("%s: error %v, want one naming %q", name, err, test.says)
		}
	}
}

// The deployer reads this file on every install. A nil selection must still
// say "none chosen" ([]), never null, and the exact contract keys.
func TestWriteAppsHandoff(t *testing.T) {
	for _, test := range []struct {
		selected []string
		want     string
	}{
		{nil, `{"schemaVersion":1,"remote":"flathub","remoteUrl":"https://dl.flathub.org/repo/flathub.flatpakrepo","flatpaks":[]}`},
		{[]string{"org.audacityteam.Audacity", "org.inkscape.Inkscape"}, `{"schemaVersion":1,"remote":"flathub","remoteUrl":"https://dl.flathub.org/repo/flathub.flatpakrepo","flatpaks":["org.audacityteam.Audacity","org.inkscape.Inkscape"]}`},
	} {
		root := t.TempDir()
		if err := writeAppsHandoff(root, test.selected); err != nil {
			t.Fatal(err)
		}
		data, err := os.ReadFile(filepath.Join(root, "install", "apps.json"))
		if err != nil {
			t.Fatal(err)
		}
		var compact map[string]any
		if err := json.Unmarshal(data, &compact); err != nil {
			t.Fatal(err)
		}
		var want map[string]any
		_ = json.Unmarshal([]byte(test.want), &want)
		if !reflect.DeepEqual(compact, want) {
			t.Fatalf("apps.json = %s, want %s", data, test.want)
		}
	}
}

func TestDecodeNativeInstallPlanFlatpaks(t *testing.T) {
	withFlatpaks := func(list string) json.RawMessage {
		return json.RawMessage(strings.TrimSuffix(nativeInstallPlanFixture, "}") + `,"flatpaks":` + list + `}`)
	}
	plan, err := decodeNativeInstallPlan(withFlatpaks(`["org.gimp.GIMP","org.inkscape.Inkscape"]`))
	if err != nil || !reflect.DeepEqual(plan.Flatpaks, []string{"org.gimp.GIMP", "org.inkscape.Inkscape"}) {
		t.Fatalf("app list did not decode: %+v %v", plan.Flatpaks, err)
	}
	if plan, err := decodeNativeInstallPlan(withFlatpaks(`[]`)); err != nil || len(plan.Flatpaks) != 0 {
		t.Fatalf("empty app list refused: %+v %v", plan.Flatpaks, err)
	}
	for _, invalid := range []string{`null`, `{}`, `"org.gimp.GIMP"`, `[null]`, `[7]`, `["gimp"]`, `["org.gimp.GIMP","org.gimp.GIMP"]`} {
		if _, err := decodeNativeInstallPlan(withFlatpaks(invalid)); err == nil {
			t.Errorf("accepted malformed app list %s", invalid)
		}
	}
}

func TestInstallPolicyAcceptsOnlyDetectedFlatpaks(t *testing.T) {
	detections := 0
	policy := installPolicy{
		support:       SupportPolicy{ExperimentalImages: true, BitLockerSupported: true},
		systemInfo:    func() SystemInfo { return SystemInfo{} },
		checkPlatform: func(InstallConfig) error { return nil },
		checkSpace:    func(context.Context, InstallConfig) error { return nil },
		profiles:      func(string, []ProfileAccount) ([]ProfileAccount, error) { return nil, nil },
		detectedApps: func() []DetectedApp {
			detections++
			return []DetectedApp{{Flatpak: "org.gimp.GIMP", Name: "GIMP", DisplayName: "GIMP 2.10.36"}}
		},
	}
	config, err := policy.validate(context.Background(), InstallConfig{Username: "alice", Flatpaks: []string{"org.gimp.GIMP"}})
	if err != nil || !reflect.DeepEqual(config.Flatpaks, []string{"org.gimp.GIMP"}) {
		t.Fatalf("detected app refused or dropped: %+v %v", config.Flatpaks, err)
	}
	if _, err := policy.validate(context.Background(), InstallConfig{Username: "alice", Flatpaks: []string{"org.kde.krita"}}); err == nil || !strings.Contains(err.Error(), "org.kde.krita") {
		t.Fatalf("undetected app accepted: %v", err)
	}
	before := detections
	if _, err := policy.validate(context.Background(), InstallConfig{Username: "alice"}); err != nil || detections != before {
		t.Fatalf("empty app list: err %v, detections %d -> %d", err, before, detections)
	}
}

func TestParseFlatpakFlag(t *testing.T) {
	for value, want := range map[string][]string{
		"":              {},
		"org.gimp.GIMP": {"org.gimp.GIMP"},
		" org.gimp.GIMP , org.inkscape.Inkscape,": {"org.gimp.GIMP", "org.inkscape.Inkscape"},
	} {
		if got := parseFlatpakFlag(value); !reflect.DeepEqual(got, want) {
			t.Errorf("parseFlatpakFlag(%q) = %v, want %v", value, got, want)
		}
	}
}

func TestHeadlessInstallRefusesUndetectedFlatpak(t *testing.T) {
	// If the app check regressed, the Secure Boot refusal below still stops
	// the install (exit 1) before the engine touches this host; only the app
	// check exits 2 here.
	oldApps, oldInfo, oldStamp := headlessDetectedApps, headlessSystemInfo, shimAuthorities
	t.Cleanup(func() { headlessDetectedApps, headlessSystemInfo, shimAuthorities = oldApps, oldInfo, oldStamp })
	shimAuthorities = "2011"
	headlessSystemInfo = func() SystemInfo {
		return SystemInfo{SecureBootOn: true, SecureBootKnown: true, UefiDbRead: true, TrustedUefiAuthorities: []string{"2023"}}
	}
	headlessDetectedApps = func() []DetectedApp { return []DetectedApp{{Flatpak: "org.gimp.GIMP"}} }
	base := []string{"-image", "ghcr.io/tuna-os/foo", "-username", "u", "-password", "p"}
	if got := headlessInstall(append(base, "-flatpaks", "org.gimp.GIMP,org.kde.krita")); got != 2 {
		t.Fatalf("headlessInstall(undetected flatpak) = %d, want 2", got)
	}
	// A detected app passes the app check and reaches the Secure Boot gate.
	if got := headlessInstall(append(base, "-flatpaks", "org.gimp.GIMP")); got != 1 {
		t.Fatalf("headlessInstall(detected flatpak) = %d, want 1 (Secure Boot refusal)", got)
	}
}
