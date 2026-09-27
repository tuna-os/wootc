package main

import (
	"os"
	"path/filepath"
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
	}
	root := t.TempDir()
	if state, _, _, err := discoverStatusState([]string{root}, func(string) error { return nil }); err != nil || state.State != "" {
		t.Fatalf("fresh missing state: %+v %v", state, err)
	}
	os.MkdirAll(filepath.Join(root, "disks"), 0700)
	os.WriteFile(filepath.Join(root, "disks", "root.disk"), []byte("existing data"), 0600)
	if _, _, _, err := discoverStatusState([]string{root}, func(string) error { return nil }); err == nil {
		t.Fatal("missing state with actual disk became fresh")
	}
}
