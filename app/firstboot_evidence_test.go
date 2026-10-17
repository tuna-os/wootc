package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

const (
	evidenceImage  = "ghcr.io/tuna-os/yellowfin:gnome"
	evidenceDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	evidenceHost   = "1234567890ABCDEF"
)

// evidenceFixture is what wootc_firstboot_evidence.py prints for a boot of
// the journaled image, as installed (not derived).
func evidenceFixture(mutate func(map[string]any)) string {
	value := map[string]any{
		"schema": 1, "state": "healthy", "phaseId": "firstboot-evidence", "sequence": 1,
		"bootId": "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", "kernel": "6.12.0-55.el10.x86_64",
		"image": map[string]any{"ref": evidenceImage, "digest": evidenceDigest, "sourceRef": evidenceImage},
		"bootCurrent": map[string]any{"bootNumber": "0004", "source": "efivarfs",
			"espPartitionGuid": "12345678-1234-5678-abcd-123456789abc", "loaderPath": `\EFI\fedora\shimx64.efi`},
		"rootDisk":    map[string]any{"path": "/wootc/disks/root.disk", "hostUuid": evidenceHost},
		"bridge":      map[string]any{"boundFolders": 6, "matchedUsers": 1, "bitlockerUnlocked": false},
		"secureBoot":  true,
		"failedUnits": []string{},
		"writtenAt":   "2026-10-17T05:00:00Z",
		"updatedBy":   "wootc-firstboot",
	}
	if mutate != nil {
		mutate(value)
	}
	data, _ := json.MarshalIndent(value, "", "  ")
	return string(data)
}

func nested(value map[string]any, key string) map[string]any { return value[key].(map[string]any) }

// evidenceInstall lays out an audited state root for one installation.
func evidenceInstall(t *testing.T, evidence string) string {
	t.Helper()
	root := t.TempDir()
	for _, dir := range []string{"install", "disks", "bundle/oci"} {
		if err := os.MkdirAll(filepath.Join(root, filepath.FromSlash(dir)), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	write := func(rel, data string) {
		if err := os.WriteFile(filepath.Join(root, filepath.FromSlash(rel)), []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("install/journal.json", statusJournalFixture(JournalArmed, "", ""))
	write("disks/root.disk", "root disk")
	write("bundle/bundle.json", `{"image":"`+evidenceImage+`","digest":"`+evidenceDigest+`","source":"predownload"}`)
	write("bundle/oci/index.json", `{}`)
	write("state.json", statusFixtureHealthy)
	if evidence != "" {
		write("install/"+firstBootEvidenceName, evidence)
	}
	return root
}

func withVolumeSerial(t *testing.T, serial volumeSerial, err error) {
	t.Helper()
	saved := firstBootVolumeSerial
	firstBootVolumeSerial = func(string) (volumeSerial, error) { return serial, err }
	t.Cleanup(func() { firstBootVolumeSerial = saved })
}

var thisVolume = volumeSerial{serial64: 0x1234567890ABCDEF, have64: true, serial32: 0x90ABCDEF, have32: true}

func TestFirstBootEvidenceParsesTheCollectorRecord(t *testing.T) {
	ev, err := parseFirstBootEvidence([]byte("\ufeff" + evidenceFixture(nil)))
	if err != nil {
		t.Fatal(err)
	}
	if ev.Image.Digest != evidenceDigest || ev.RootDisk.HostUUID != evidenceHost || ev.Bridge.BoundFolders != 6 ||
		ev.BootCurrent.LoaderPath != `\EFI\fedora\shimx64.efi` || !ev.SecureBoot {
		t.Fatalf("parsed %+v", ev)
	}
	// failedUnits is reported, not required; an undecodable boot entry is
	// still a record.
	if _, err := parseFirstBootEvidence([]byte(evidenceFixture(func(v map[string]any) {
		v["bootCurrent"] = map[string]any{"source": "unavailable"}
		delete(v, "failedUnits")
		delete(v, "phaseId")
	}))); err != nil {
		t.Fatalf("optional fields required: %v", err)
	}
}

func TestFirstBootEvidenceRefusesUntrustedShapes(t *testing.T) {
	good := evidenceFixture(nil)
	cases := map[string]string{
		"unknown top-level field": evidenceFixture(func(v map[string]any) { v["account"] = "alice" }),
		"unknown nested field":    evidenceFixture(func(v map[string]any) { nested(v, "image")["tag"] = "lts" }),
		"repeated key":            strings.Replace(good, `"state": "healthy"`, `"state": "failed", "state": "healthy"`, 1),
		"case-folded key":         strings.Replace(good, `"secureBoot"`, `"SecureBoot"`, 1),
		"null value":              strings.Replace(good, `"kernel": "6.12.0-55.el10.x86_64"`, `"kernel": null`, 1),
		"null object":             evidenceFixture(func(v map[string]any) { v["rootDisk"] = nil }),
		"float integer":           strings.Replace(good, `"sequence": 1`, `"sequence": 1.5`, 1),
		"trailing data":           good + `{}`,
		"not an object":           `[]`,
		"missing image":           evidenceFixture(func(v map[string]any) { delete(v, "image") }),
		"missing boot entry":      evidenceFixture(func(v map[string]any) { delete(v, "bootCurrent") }),
		"missing digest":          evidenceFixture(func(v map[string]any) { delete(nested(v, "image"), "digest") }),
		"missing host uuid":       evidenceFixture(func(v map[string]any) { delete(nested(v, "rootDisk"), "hostUuid") }),
		"bad digest":              evidenceFixture(func(v map[string]any) { nested(v, "image")["digest"] = "sha256:abc" }),
		"bad boot id":             evidenceFixture(func(v map[string]any) { v["bootId"] = "yesterday" }),
		"bad host uuid":           evidenceFixture(func(v map[string]any) { nested(v, "rootDisk")["hostUuid"] = "c:" }),
		"other root.disk":         evidenceFixture(func(v map[string]any) { nested(v, "rootDisk")["path"] = "/wootc/disks/old.disk" }),
		"unhealthy":               evidenceFixture(func(v map[string]any) { v["state"] = "failed" }),
		"newer schema":            evidenceFixture(func(v map[string]any) { v["schema"] = 2 }),
		"foreign writer":          evidenceFixture(func(v map[string]any) { v["updatedBy"] = "someone" }),
		"control character":       evidenceFixture(func(v map[string]any) { v["kernel"] = "6.12\n[PASS] fake" }),
		"impossible bridge":       evidenceFixture(func(v map[string]any) { nested(v, "bridge")["matchedUsers"] = 7 }),
		"bad loader path":         evidenceFixture(func(v map[string]any) { nested(v, "bootCurrent")["loaderPath"] = `C:\x.efi` }),
		"bad write time":          evidenceFixture(func(v map[string]any) { v["writtenAt"] = "now" }),
		"oversize":                strings.Replace(good, `"kernel"`, `"phaseId": "`+strings.Repeat("x", firstBootEvidenceMaxBytes)+`", "kernel"`, 1),
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := parseFirstBootEvidence([]byte(data)); err == nil {
				t.Fatalf("accepted %s", name)
			}
		})
	}
}

func TestFirstBootAssessment(t *testing.T) {
	derived := evidenceFixture(func(v map[string]any) {
		nested(v, "image")["ref"] = "localhost/wootc-ntfs-injected:latest"
		nested(v, "image")["digest"] = "sha256:" + strings.Repeat("b", 64)
	})
	cases := []struct {
		name     string
		evidence string
		volume   volumeSerial
		mutate   func(root string)
		verdict  string
		reason   string
	}{
		{name: "missing file is waiting for the first boot", verdict: FirstBootWaiting},
		{name: "matching record is verified", evidence: evidenceFixture(nil), verdict: FirstBootVerified},
		{name: "derived image verifies through the recorded selection", evidence: derived, verdict: FirstBootVerified},
		{name: "low 32 bits verify when the full serial is unavailable", evidence: evidenceFixture(nil),
			volume: volumeSerial{serial32: 0x90ABCDEF, have32: true}, verdict: FirstBootVerified},
		{name: "another image", evidence: evidenceFixture(func(v map[string]any) {
			nested(v, "image")["ref"] = "ghcr.io/tuna-os/yellowfin:kde"
			delete(nested(v, "image"), "sourceRef")
		}), verdict: FirstBootMismatch, reason: "not the selected"},
		{name: "another selection recorded by the deployer", evidence: evidenceFixture(func(v map[string]any) {
			nested(v, "image")["sourceRef"] = "ghcr.io/tuna-os/yellowfin:kde"
		}), verdict: FirstBootMismatch, reason: "installed from"},
		{name: "another digest of the selected image", evidence: evidenceFixture(func(v map[string]any) {
			nested(v, "image")["digest"] = "sha256:" + strings.Repeat("c", 64)
		}), verdict: FirstBootMismatch, reason: "digest"},
		{name: "root.disk on another volume", evidence: evidenceFixture(func(v map[string]any) {
			nested(v, "rootDisk")["hostUuid"] = "FEDCBA0987654321"
		}), verdict: FirstBootMismatch, reason: "volume"},
		{name: "the full serial decides when it is available", evidence: evidenceFixture(func(v map[string]any) {
			nested(v, "rootDisk")["hostUuid"] = "FFFFFFFF90ABCDEF"
		}), verdict: FirstBootMismatch, reason: "volume"},
		{name: "another volume by its low 32 bits", evidence: evidenceFixture(nil),
			volume: volumeSerial{serial32: 0x11111111, have32: true}, verdict: FirstBootMismatch, reason: "volume"},
		{name: "unknown field", evidence: evidenceFixture(func(v map[string]any) { v["extra"] = true }), verdict: FirstBootInvalid},
		{name: "oversize file", evidence: strings.Repeat(" ", firstBootEvidenceMaxBytes) + evidenceFixture(nil), verdict: FirstBootInvalid},
		{name: "no record of the selected image", evidence: evidenceFixture(nil), verdict: FirstBootUnverifiable,
			mutate: func(root string) {
				os.Remove(filepath.Join(root, "install", "journal.json"))
				os.RemoveAll(filepath.Join(root, "bundle"))
			}},
		{name: "root.disk gone from this volume", evidence: evidenceFixture(nil), verdict: FirstBootUnverifiable,
			mutate: func(root string) { os.Remove(filepath.Join(root, "disks", "root.disk")) }},
		{name: "unreadable journal", evidence: evidenceFixture(nil), verdict: FirstBootUnverifiable,
			mutate: func(root string) {
				os.WriteFile(filepath.Join(root, "install", "journal.json"), []byte(`{"schema":1,"schema":1}`), 0o600)
			}},
		{name: "volume identity unavailable", evidence: evidenceFixture(nil), volume: volumeSerial{}, verdict: FirstBootMismatch, reason: "unavailable"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			volume := tc.volume
			if volume == (volumeSerial{}) && !strings.Contains(tc.name, "unavailable") {
				volume = thisVolume
			}
			withVolumeSerial(t, volume, nil)
			root := evidenceInstall(t, tc.evidence)
			if tc.mutate != nil {
				tc.mutate(root)
			}
			got := assessFirstBootAt(root)
			if got.Verdict != tc.verdict || !strings.Contains(got.Reason, tc.reason) || got.Message == "" {
				t.Fatalf("assessment = %+v, want %s (%s)", got, tc.verdict, tc.reason)
			}
			if (got.Verdict == FirstBootVerified) != (got.Kernel != "" && got.Bridge != nil && got.SecureBoot != nil) {
				t.Fatalf("summary fields only for verified evidence: %+v", got)
			}
			if !strings.Contains(got.Message, installedSystemName()) {
				t.Fatalf("message does not name the installed system: %q", got.Message)
			}
		})
	}
}

func TestFirstBootVolumeErrorIsUnverifiable(t *testing.T) {
	withVolumeSerial(t, volumeSerial{}, fmt.Errorf("no volume handle"))
	if got := assessFirstBootAt(evidenceInstall(t, evidenceFixture(nil))); got.Verdict != FirstBootUnverifiable {
		t.Fatalf("assessment = %+v", got)
	}
}

func TestFirstBootSymlinkIsNotRead(t *testing.T) {
	withVolumeSerial(t, thisVolume, nil)
	root := evidenceInstall(t, "")
	elsewhere := filepath.Join(t.TempDir(), "evidence.json")
	if err := os.WriteFile(elsewhere, []byte(evidenceFixture(nil)), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, firstBootEvidencePath(root)); err != nil {
		t.Skip("symlinks unavailable:", err)
	}
	if got := assessFirstBootAt(root); got.Verdict != FirstBootInvalid {
		t.Fatalf("followed a link: %+v", got)
	}
}

// statusHealthy is the harness's own test of `status` output (run-e2e.sh).
var statusHealthy = regexp.MustCompile(`"state"[[:space:]]*:[[:space:]]*"healthy"`)

func TestStatusReportsHealthyOnlyWithVerifiedEvidence(t *testing.T) {
	withVolumeSerial(t, thisVolume, nil)
	recorded := LifecycleState{State: StateHealthy, UpdatedAt: "2026-10-17T05:00:00Z", UpdatedBy: "wootc-firstboot"}
	for name, tc := range map[string]struct {
		evidence string
		healthy  bool
		verdict  string
	}{
		"before the first boot": {"", false, FirstBootWaiting},
		"verified":              {evidenceFixture(nil), true, FirstBootVerified},
		"mismatched": {evidenceFixture(func(v map[string]any) { nested(v, "rootDisk")["hostUuid"] = "FEDCBA0987654321" }),
			false, FirstBootMismatch},
	} {
		t.Run(name, func(t *testing.T) {
			report := statusReportAt(evidenceInstall(t, tc.evidence), recorded)
			data, err := marshalJSON(report)
			if err != nil {
				t.Fatal(err)
			}
			if statusHealthy.Match(data) != tc.healthy || report.FirstBoot == nil || report.FirstBoot.Verdict != tc.verdict {
				t.Fatalf("status output:\n%s", data)
			}
			if !tc.healthy && (report.State != StateDeployed || report.RecordedState != StateHealthy) {
				t.Fatalf("unverified healthy must read as installed and waiting: %+v", report)
			}
			if tc.healthy && report.RecordedState != "" {
				t.Fatalf("verified status overruled state.json: %+v", report)
			}
		})
	}
	// The deployer's own "deployed" is reported as is, waiting for the boot.
	report := statusReportAt(evidenceInstall(t, ""), LifecycleState{State: StateDeployed, UpdatedAt: "2026-10-17T05:00:00Z", UpdatedBy: "deployer"})
	if report.State != StateDeployed || report.RecordedState != "" || report.FirstBoot.Verdict != FirstBootWaiting ||
		!strings.Contains(report.FirstBoot.Message, "waiting for its first boot") {
		t.Fatalf("deployed report = %+v", report)
	}
	// Earlier lifecycle states have no first boot to report.
	if report := statusReportAt(evidenceInstall(t, evidenceFixture(nil)), LifecycleState{State: StateArmed}); report.FirstBoot != nil || report.State != StateArmed {
		t.Fatalf("armed report = %+v", report)
	}
}

func TestRecoveryClassifiesUnverifiedHealthyAsInstalledAndWaiting(t *testing.T) {
	withVolumeSerial(t, thisVolume, nil)
	if got := classifyInstall(observeInstallAt(evidenceInstall(t, ""), nil)); got.Cause != CauseDeployed {
		t.Fatalf("unverified healthy classified %s", got.Cause)
	}
	if got := classifyInstall(observeInstallAt(evidenceInstall(t, evidenceFixture(nil)), nil)); got.Cause != CauseHealthy {
		t.Fatalf("verified healthy classified %s", got.Cause)
	}
	state, err := readNativeStartupLifecycle(evidenceInstall(t, ""))
	if err != nil || state.State != StateDeployed {
		t.Fatalf("native startup lifecycle = %+v, %v", state, err)
	}
}

func TestFirstBootEvidenceLifecycle(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "install"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(firstBootEvidencePath(root), []byte(evidenceFixture(nil)), 0o600); err != nil {
		t.Fatal(err)
	}
	// A surviving record alone is an install attempt uninstall must find.
	if !hasInstallAttempt(root) {
		t.Fatal("orphaned first-boot evidence is not an install attempt")
	}
	if err := discardStaleFirstBootEvidence(root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(firstBootEvidencePath(root)); !os.IsNotExist(err) {
		t.Fatalf("stale evidence survived: %v", err)
	}
	if err := discardStaleFirstBootEvidence(root); err != nil {
		t.Fatalf("absent evidence: %v", err)
	}
}
