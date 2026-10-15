package main

import (
	"os"
	"strings"
	"testing"
)

const boundDirective = `{"schemaVersion":1,"runId":"current","directiveId":"1234567890abcdef1234567890abcdef","action":"install"}`
const boundReport = `{"schemaVersion":1,"runId":"current","directiveId":"1234567890abcdef1234567890abcdef","action":"install","screen":"progress","installDriven":true,"installBtnDisabled":null,"hint":"","progressStep":"","error":null,"selectedRef":"image","imageMismatch":false}`

func TestE2EDriveReportRefusesUnrelatedAndAmbiguousWrites(t *testing.T) {
	t.Setenv("WOOTC_E2E_DRIVE", "1")
	removeE2EFiles(t)
	defer removeE2EFiles(t)
	if err := os.WriteFile(e2eDrivePath("e2e-drive.json"), []byte(boundDirective), 0600); err != nil {
		t.Fatal(err)
	}
	(&App{}).E2EDriveReport(boundReport)
	path := e2eDrivePath("e2e-drive-state.json")
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	cases := []string{`{"screen":"done"}`, strings.Replace(boundReport, `"current"`, `"old"`, 1),
		strings.Replace(boundReport, `"1234567890abcdef1234567890abcdef"`, `"00000000000000000000000000000000"`, 1),
		strings.Replace(boundReport, `"schemaVersion":1`, `"schemaVersion":true`, 1),
		strings.Replace(boundReport, `"screen":"progress"`, `"screen":"progress","screen":"done"`, 1),
		boundReport + boundReport, strings.Repeat("x", 16385)}
	for _, report := range cases {
		(&App{}).E2EDriveReport(report)
		after, err := os.ReadFile(path)
		if err != nil || string(after) != string(before) {
			t.Fatal("unverified report replaced known report")
		}
	}
	if err := os.WriteFile(e2eDrivePath("e2e-drive.json"), []byte(strings.Replace(boundDirective, `"runId":"current"`, `"runId":"old","runId":"current"`, 1)), 0600); err != nil {
		t.Fatal(err)
	}
	(&App{}).E2EDriveReport(strings.Replace(boundReport, `"progress"`, `"done"`, 1))
	after, err := os.ReadFile(path)
	if err != nil || string(after) != string(before) {
		t.Fatal("ambiguous directive allowed report publication")
	}
	if err := os.Remove(e2eDrivePath("e2e-drive.json")); err != nil {
		t.Fatal(err)
	}
	(&App{}).E2EDriveReport(strings.Replace(boundReport, `"progress"`, `"done"`, 1))
	after, err = os.ReadFile(path)
	if err != nil || string(after) != string(before) {
		t.Fatal("missing directive allowed report publication")
	}
}

func TestE2EDriveToleratesBOMDirective(t *testing.T) {
	t.Setenv("WOOTC_E2E_DRIVE", "1")
	removeE2EFiles(t)
	defer removeE2EFiles(t)
	// PowerShell 5.1 Set-Content -Encoding UTF8 prefixes a BOM; the drive
	// loop must survive one (runs 36399679919/36413017019/36420437461).
	bom := append([]byte("\xef\xbb\xbf"), []byte(boundDirective)...)
	if err := os.WriteFile(e2eDrivePath("e2e-drive.json"), bom, 0600); err != nil {
		t.Fatal(err)
	}
	if got := (&App{}).E2EDriveDirective(); got != boundDirective {
		t.Fatalf("BOM directive unreadable, got %q", got)
	}
	(&App{}).E2EDriveReport(boundReport)
	after, err := os.ReadFile(e2eDrivePath("e2e-drive-state.json"))
	if err != nil || string(after) != boundReport {
		t.Fatal("BOM directive blocked bound report publication")
	}
}

// The native shell builds reports from tests/unit/fixtures/e2e-drive
// (shell/Wootc.Shell.Tests/E2EDriveTests.cs). The engine must bind each
// golden report to its golden directive, and to no other.
func TestE2EDriveSharedNativeGoldens(t *testing.T) {
	read := func(name string) []byte {
		raw, err := os.ReadFile("../tests/unit/fixtures/e2e-drive/" + name)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	install, reboot := read("directive-install.json"), read("directive-reboot.json")
	for _, name := range []string{"report-install-ready.json", "report-install-mismatch.json", "report-install-done.json"} {
		if !e2eBoundDriveReport(read(name), install) {
			t.Errorf("%s is not bound to the install directive", name)
		}
		if e2eBoundDriveReport(read(name), reboot) {
			t.Errorf("%s binds to the reboot directive", name)
		}
	}
	if !e2eBoundDriveReport(read("report-reboot-done.json"), reboot) || e2eBoundDriveReport(read("report-reboot-done.json"), install) {
		t.Error("the reboot report must bind only to the reboot directive")
	}
}
