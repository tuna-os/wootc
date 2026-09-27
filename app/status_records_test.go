package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStatusRecordsRefuseAmbiguousLifecycleInsteadOfFreshRoute(t *testing.T) {
	for _, record := range []string{
		`{"state":"failed","state":"healthy","updatedAt":"2026-09-27T05:00:00Z","updatedBy":"writer"}`,
		`{"state":"healthy","state":"failed","updatedAt":"2026-09-27T05:00:00Z","updatedBy":"writer"}`,
		`{"state":"healthy","State":"failed","updatedAt":"2026-09-27T05:00:00Z","updatedBy":"writer"}`,
		`{"state":"healthy","updatedAt":"2026-09-27T05:00:00Z","updatedBy":"writer","unknown":true}`,
		`{"state":"healthy","updatedAt":"2026-09-27T05:00:00Z","updatedBy":"writer","phase":null}`,
	} {
		root := statusFixture(t, record)
		if _, _, found, err := discoverStatusState([]string{root}, func(string) error { return nil }); err == nil || found {
			t.Fatalf("ambiguous attempt became selected/fresh: %v %v", found, err)
		}
		if _, err := readNativeStartupLifecycle(root); err == nil {
			t.Fatal("native getter erased malformed lifecycle")
		}
	}
	root := t.TempDir()
	if state, err := readNativeStartupLifecycle(root); err != nil || state.State != "" {
		t.Fatalf("fresh missing state: %+v %v", state, err)
	}
	os.MkdirAll(filepath.Join(root, "disks"), 0700)
	os.WriteFile(filepath.Join(root, "disks", "root.disk"), []byte("existing data"), 0600)
	if _, err := readNativeStartupLifecycle(root); err == nil {
		t.Fatal("missing state with actual disk became fresh")
	}
}

func TestStatusRecordsRecoveryMissingIsDistinctFromMalformed(t *testing.T) {
	root := t.TempDir()
	if verdict, err := readNativeStartupRecovery(root); err != nil || verdict.Verdict != "" {
		t.Fatalf("fresh recovery %+v %v", verdict, err)
	}
	os.MkdirAll(filepath.Join(root, "install"), 0700)
	path := filepath.Join(root, "install", "recovery-verdict.json")
	valid := `{"verdict":"failed","title":"Previous attempt failed","message":"Failure","untouched":false,"canTryAgain":false,"canRemove":true,"canRepairBoot":false,"timestamp":"2026-09-27T05:00:00Z"}`
	for _, record := range []string{`{}`, `null`, strings.Replace(valid, `"verdict":"failed"`, `"verdict":"failed","verdict":"healthy"`, 1), strings.Replace(valid, `"verdict":"failed"`, `"verdict":"healthy","verdict":"failed"`, 1), strings.Replace(valid, `"canRemove":true`, `"canRemove":null`, 1), strings.Replace(valid, `"timestamp":"2026-09-27T05:00:00Z"`, `"timestamp":"bad"`, 1), strings.Replace(valid, `"verdict":"failed"`, `"state":"failed"`, 1)} {
		os.WriteFile(path, []byte(record), 0600)
		if _, err := readNativeStartupRecovery(root); err == nil {
			t.Fatalf("malformed recovery erased: %s", record)
		}
	}
	os.WriteFile(path, []byte(valid), 0600)
	if verdict, err := readNativeStartupRecovery(root); err != nil || verdict.Verdict != VerdictFailed {
		t.Fatalf("actual failed verdict %+v %v", verdict, err)
	}
}
