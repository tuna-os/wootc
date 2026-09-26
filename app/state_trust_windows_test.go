//go:build windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func TestStateDescriptorTrust(t *testing.T) {
	tests := []struct {
		name, sddl     string
		volume, accept bool
	}{
		{"protected", stateDirectorySDDL, false, true},
		{"system owner", "O:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", false, true},
		{"legacy readonly", "O:BAD:(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FR;;;BU)", false, true},
		{"user owner", "O:BUD:P(A;;FA;;;SY)(A;;FA;;;BA)", false, false},
		{"null DACL", "O:BAD:NO_ACCESS_CONTROL", false, false},
		{"user write", "O:BAD:(A;;FW;;;BU)", false, false},
		{"everyone write", "O:BAD:(A;;FW;;;WD)", false, false},
		{"user delete", "O:BAD:(A;;SD;;;BU)", false, false},
		{"user delete child", "O:BAD:(A;;DC;;;BU)", false, false},
		{"user change ACL", "O:BAD:(A;;WD;;;BU)", false, false},
		{"user change owner", "O:BAD:(A;;WO;;;BU)", false, false},
		{"future writable children", "O:BAD:(A;OICIIO;FW;;;BU)", false, false},
		{"creator owner children", "O:BAD:(A;OICIIO;FA;;;CO)(A;;FA;;;BA)", false, true},
		{"volume create child allowed", "O:BAD:(A;;0x00000006;;;BU)(A;;FA;;;BA)", true, true},
		{"volume delete child refused", "O:BAD:(A;;DC;;;BU)(A;;FA;;;BA)", true, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			sd, err := windows.SecurityDescriptorFromString(tc.sddl)
			if err != nil {
				t.Fatal(err)
			}
			err = validateStateDescriptor(sd, tc.volume)
			if (err == nil) != tc.accept {
				t.Fatalf("accept=%v, error=%v", tc.accept, err)
			}
		})
	}
}

func applyTestDACL(t *testing.T, path, sddl string) {
	t.Helper()
	sd, err := windows.SecurityDescriptorFromString(sddl)
	if err != nil {
		t.Fatal(err)
	}
	acl, _, err := sd.DACL()
	if err != nil {
		t.Fatal(err)
	}
	if err := windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil); err != nil {
		t.Fatal(err)
	}
}

func trustedFixture(t *testing.T) string {
	t.Helper()
	// Atomic creation explicitly sets the owner to Administrators. These tests
	// must run elevated; an access-denied is a failure, not a vacuous skip.
	root := filepath.Join(t.TempDir(), "wootc")
	if err := prepareTrustedStateTree(root); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestStateTreeNewAndOfflineRerun(t *testing.T) {
	root := trustedFixture(t)
	install := filepath.Join(root, "install")
	if err := os.Mkdir(install, 0700); err != nil {
		t.Fatal(err)
	}
	manifest := filepath.Join(install, "SHA256SUMS")
	if err := os.WriteFile(manifest, []byte("admin-staged fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := prepareTrustedStateTree(root); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(manifest)
	if err != nil || string(data) != "admin-staged fixture" {
		t.Fatalf("fixture changed: %q %v", data, err)
	}
}

func TestStateTreeRejectsWritableManifestWithoutRepair(t *testing.T) {
	root := trustedFixture(t)
	manifest := filepath.Join(root, "SHA256SUMS")
	if err := os.WriteFile(manifest, []byte("planted"), 0600); err != nil {
		t.Fatal(err)
	}
	applyTestDACL(t, manifest, "D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FW;;;BU)")
	if err := prepareTrustedStateTree(root); err == nil || !strings.Contains(err.Error(), "SHA256SUMS") {
		t.Fatalf("wanted planted manifest refusal: %v", err)
	}
	if err := inspectStateObject(manifest, false); err == nil {
		t.Fatal("unsafe ACL was silently repaired")
	}
	data, err := os.ReadFile(manifest)
	if err != nil || string(data) != "planted" {
		t.Fatalf("planted content changed: %q %v", data, err)
	}
}

func TestStateTreeRejectsReparsePoint(t *testing.T) {
	root := trustedFixture(t)
	target := t.TempDir()
	if err := os.Symlink(target, filepath.Join(root, "install")); err != nil {
		t.Fatal(err)
	}
	if err := prepareTrustedStateTree(root); err == nil || !strings.Contains(err.Error(), "reparse") {
		t.Fatalf("wanted reparse refusal: %v", err)
	}
}
