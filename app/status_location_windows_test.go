//go:build windows

package main

import (
	"fmt"
	"golang.org/x/sys/windows"
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

func TestStatusAuditPreservesPrivateBytesAndDescriptors(t *testing.T) {
	root := trustedFixture(t)
	path := filepath.Join(root, "state.json")
	if err := os.WriteFile(path, []byte(statusFixtureHealthy), 0600); err != nil {
		t.Fatal(err)
	}
	snapshot := func() string {
		t.Helper()
		var result strings.Builder
		err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			info, err := os.Lstat(path)
			if err != nil {
				return err
			}
			sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
			if err != nil {
				return err
			}
			fmt.Fprintf(&result, "%s|%d|%d|%s\n", path, info.Mode(), info.ModTime().UnixNano(), sd.String())
			if info.Mode().IsRegular() {
				data, err := os.ReadFile(path)
				if err != nil {
					return err
				}
				result.Write(data)
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		return result.String()
	}
	before := snapshot()
	audit := func(root string) error {
		return auditStatusTree(root, func(path string) error { return inspectStateObject(path, false) })
	}
	out := captureStdout(t, func() {
		code := headlessStatusWithReader(func() (LifecycleState, bool, error) {
			state, _, found, err := discoverStatusState([]string{root}, audit)
			return state, found, err
		})
		if code != 0 {
			t.Fatalf("status exit %d", code)
		}
	})
	if !strings.Contains(out, `"state": "healthy"`) {
		t.Fatalf("missing observed lifecycle: %q", out)
	}
	if after := snapshot(); after != before {
		t.Fatal("status changed private bytes, names, timestamps or security descriptors")
	}
	applyTestDACL(t, path, "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FW;;;BU)")
	before = snapshot()
	out = captureStdout(t, func() {
		code := headlessStatusWithReader(func() (LifecycleState, bool, error) {
			state, _, found, err := discoverStatusState([]string{root}, audit)
			return state, found, err
		})
		if code != 1 {
			t.Fatalf("unsafe status exit %d", code)
		}
	})
	if out != "" || snapshot() != before {
		t.Fatal("unsafe status printed a guessed state or repaired files/permissions")
	}
}
