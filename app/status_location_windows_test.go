//go:build windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStatusAuditRejectsUnsafeTreeWithoutRepair(t *testing.T) {
	root := trustedFixture(t)
	path := filepath.Join(root, "state.json")
	if err := os.WriteFile(path, []byte(statusFixtureHealthy), 0600); err != nil {
		t.Fatal(err)
	}
	audit := func(root string) error {
		return auditStatusTree(root, func(path string) error { return inspectStateObject(path, false) })
	}
	if _, _, found, err := discoverStatusState([]string{root}, audit); err != nil || !found {
		t.Fatalf("trusted state: %v %v", found, err)
	}
	applyTestDACL(t, path, "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FW;;;BU)")
	if _, _, found, err := discoverStatusState([]string{root}, audit); err == nil || found {
		t.Fatalf("writable state accepted: %v %v", found, err)
	}
	if err := inspectStateObject(path, false); err == nil {
		t.Fatal("status repaired an unsafe ACL")
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != statusFixtureHealthy {
		t.Fatalf("status changed unsafe state: %q %v", data, err)
	}
}

func TestStatusAuditRejectsReparseTree(t *testing.T) {
	root := trustedFixture(t)
	if err := os.Symlink(t.TempDir(), filepath.Join(root, "install")); err != nil {
		t.Fatal(err)
	}
	err := auditStatusTree(root, func(path string) error { return inspectStateObject(path, false) })
	if err == nil || !strings.Contains(err.Error(), "reparse") {
		t.Fatalf("reparse audit=%v", err)
	}
}
