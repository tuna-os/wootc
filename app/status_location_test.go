package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func statusFixture(t *testing.T, data string) string {
	t.Helper()
	root := t.TempDir()
	if data != "" {
		if err := os.WriteFile(filepath.Join(root, "state.json"), []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

const statusFixtureHealthy = `{"state":"healthy","updatedAt":"2026-09-27T05:00:00Z","updatedBy":"wootc-firstboot"}`

func TestStatusDiscoverySelectsInstallationPastPayload(t *testing.T) {
	payload := statusFixture(t, "")
	if err := os.WriteFile(filepath.Join(payload, "wootc.exe"), []byte("staged executable"), 0600); err != nil {
		t.Fatal(err)
	}
	installed := statusFixture(t, "\ufeff"+statusFixtureHealthy)
	var audited []string
	state, root, found, err := discoverStatusState([]string{payload, installed}, func(path string) error { audited = append(audited, path); return nil })
	if err != nil || !found || root != installed || state.State != StateHealthy {
		t.Fatalf("state=%+v root=%s found=%v err=%v", state, root, found, err)
	}
	if len(audited) != 2 {
		t.Fatalf("only %d roots audited", len(audited))
	}
	_, root, found, err = discoverStatusState([]string{installed, payload}, func(string) error { return nil })
	if err != nil || !found || root != installed {
		t.Fatalf("reverse discovery: %s %v %v", root, found, err)
	}
}

func TestStatusDiscoveryRejectsCompetingInstallations(t *testing.T) {
	stale := statusFixture(t, `{"state":"armed","updatedAt":"2025-01-01T00:00:00Z","updatedBy":"old-installer"}`)
	installed := statusFixture(t, statusFixtureHealthy)
	for _, roots := range [][]string{{stale, installed}, {installed, stale}} {
		_, root, found, err := discoverStatusState(roots, func(string) error { return nil })
		if err == nil || !strings.Contains(err.Error(), "ambiguous") || found || root != "" {
			t.Fatalf("competing roots selected: %s %v %v", root, found, err)
		}
	}
}

func TestStatusDiscoveryRefusesUnsafeAndMalformedAttempts(t *testing.T) {
	for _, data := range []string{"{", `{}`, `null`, `{"state":"invented","updatedAt":"2026-09-27T05:00:00Z","updatedBy":"writer"}`, `{"state":"healthy"}`, strings.Repeat(" ", 65537)} {
		t.Run(fmt.Sprintf("bytes-%d", len(data)), func(t *testing.T) {
			root := statusFixture(t, data)
			_, _, found, err := discoverStatusState([]string{root}, func(string) error { return nil })
			if err == nil || found {
				t.Fatalf("invalid state became status: %v %v", found, err)
			}
		})
	}
	root := statusFixture(t, statusFixtureHealthy)
	_, _, found, err := discoverStatusState([]string{root}, func(string) error { return fmt.Errorf("unsafe ACL or reparse") })
	if err == nil || found || !strings.Contains(err.Error(), "unsafe") {
		t.Fatalf("unaudited state accepted: %v %v", found, err)
	}
	incomplete := statusFixture(t, "")
	if err := os.MkdirAll(filepath.Join(incomplete, "disks"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(incomplete, "disks", "root.disk"), []byte("partial installation"), 0600); err != nil {
		t.Fatal(err)
	}
	_, _, found, err = discoverStatusState([]string{incomplete}, func(string) error { return nil })
	if err == nil || found {
		t.Fatalf("attempt missing state became absent/success: %v %v", found, err)
	}
}

func TestStatusDiscoveryAbsentDoesNotCreateFiles(t *testing.T) {
	parent := t.TempDir()
	missing := filepath.Join(parent, "wootc")
	_, _, found, err := discoverStatusState([]string{missing}, func(string) error { t.Fatal("audited nonexistent tree"); return nil })
	if err != nil || found {
		t.Fatalf("absent: %v %v", found, err)
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Fatalf("status created missing directory: %v", err)
	}
	if err := initializeStateTrustForInvocation([]string{"wootc.exe", "status"}); err != nil {
		t.Fatal(err)
	}
}

func TestStatusInvocationSkipsOnlyReadOnlyStatusInitialization(t *testing.T) {
	for _, args := range [][]string{{"wootc.exe", "status"}, {"wootc.exe", "status", "unexpected"}, {"wootc.exe"}, {"wootc.exe", "install"}, {"wootc.exe", "serve"}, {"wootc.exe", "recover", "--status"}, {"wootc.exe", "status-other"}} {
		calls := 0
		blocked := fmt.Errorf("initializer sentinel")
		err := initializeStateTrustForInvocationWith(args, func() error { calls++; return blocked })
		skip := len(args) > 1 && args[1] == "status"
		if skip && (calls != 0 || err != nil) {
			t.Fatalf("status invoked mutating initialization: %v %d", err, calls)
		}
		if !skip && (calls != 1 || err != blocked) {
			t.Fatalf("other invocation lost initialization gate: %v %d", err, calls)
		}
	}
}
