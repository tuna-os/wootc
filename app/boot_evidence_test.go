package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func bootEvidenceFixture() (InstallationIdentity, LinuxBootEvidence) {
	p := InstallationIdentity{1, "0123456789abcdef0123456789abcdef", "2026-09-27T04:00:00Z", "ghcr.io/tuna-os/yellowfin:gnome", "12345678-1234-1234-1234-123456789abc", `\EFI\fedora\shimx64.efi`, "ABCD123456789012", "/wootc/disks/root.disk"}
	e := LinuxBootEvidence{SchemaVersion: 1, InstallationID: p.InstallationID, State: StateHealthy, Kernel: "6.12.1", Image: "localhost/wootc-deploy:current", ImageDigest: "sha256:" + strings.Repeat("a", 64), SourceImageRef: p.ImageRef, BootCurrent: LinuxBootCurrent{"0004", p.EspPartitionGuid, p.LoaderPath}, RootDisk: LinuxRootDisk{p.RootDiskPath, p.HostUUID}, Bridge: LinuxBridgeEvidence{BoundFolders: 1, MatchedUsers: 1, MatchedProfiles: []LinuxMatchedProfile{{"A", "a", "/mnt/windows/Users/A"}}, Bindings: []LinuxBridgeBinding{{"/mnt/windows/Users/A/Documents", "/home/a/Documents", "a"}}}, SecureBoot: true, FailedUnits: []string{}, WrittenAt: "2026-09-27T04:05:00Z", UpdatedBy: "wootc-firstboot"}
	return p, e
}

func TestLinuxBootEvidenceRejectsWrongInstallation(t *testing.T) {
	p, original := bootEvidenceFixture()
	if err := validateLinuxBootEvidence(original, p, p.EspPartitionGuid, p.HostUUID); err != nil {
		t.Fatal(err)
	}
	cases := map[string]func(*LinuxBootEvidence){
		"old installation":       func(e *LinuxBootEvidence) { e.InstallationID = strings.Repeat("f", 32) },
		"wrong ESP":              func(e *LinuxBootEvidence) { e.BootCurrent.EspPartitionGuid = "aaaaaaaa-1234-1234-1234-123456789abc" },
		"wrong loader":           func(e *LinuxBootEvidence) { e.BootCurrent.LoaderPath = `\EFI\Microsoft\Boot\bootmgfw.efi` },
		"wrong boot number":      func(e *LinuxBootEvidence) { e.BootCurrent.BootNumber = "unknown" },
		"wrong host":             func(e *LinuxBootEvidence) { e.RootDisk.HostUUID = "1234567890123456" },
		"wrong disk":             func(e *LinuxBootEvidence) { e.RootDisk.Path = "/wootc/disks/other.disk" },
		"missing image digest":   func(e *LinuxBootEvidence) { e.ImageDigest = "" },
		"wrong source":           func(e *LinuxBootEvidence) { e.SourceImageRef = "ghcr.io/tuna-os/bonito:kde" },
		"missing kernel":         func(e *LinuxBootEvidence) { e.Kernel = "" },
		"stale timestamp":        func(e *LinuxBootEvidence) { e.WrittenAt = "2026-09-26T04:00:00Z" },
		"failed service":         func(e *LinuxBootEvidence) { e.FailedUnits = []string{"wootc-passthrough.service"} },
		"missing service result": func(e *LinuxBootEvidence) { e.FailedUnits = nil },
		"missing bridge result":  func(e *LinuxBootEvidence) { e.Bridge.Bindings = nil },
		"wrong folder count":     func(e *LinuxBootEvidence) { e.Bridge.BoundFolders = 2 },
		"wrong user count":       func(e *LinuxBootEvidence) { e.Bridge.MatchedUsers = 0 },
		"wrong state":            func(e *LinuxBootEvidence) { e.State = StateDeployed },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			e := original
			mutate(&e)
			if err := validateLinuxBootEvidence(e, p, p.EspPartitionGuid, p.HostUUID); err == nil {
				t.Fatal("accepted invalid boot proof")
			}
		})
	}
	if err := validateLinuxBootEvidence(original, p, "aaaaaaaa-1234-1234-1234-123456789abc", p.HostUUID); err == nil {
		t.Fatal("accepted different current ESP")
	}
	if err := validateLinuxBootEvidence(original, p, p.EspPartitionGuid, "1234567890123456"); err == nil {
		t.Fatal("accepted different current volume")
	}
}

func TestLinuxBootEvidenceRequiresMeasuredFields(t *testing.T) {
	_, e := bootEvidenceFixture()
	data, _ := json.Marshal(e)
	for _, name := range []string{"secureBoot", "failedUnits", "bridge", "kernel", "imageDigest", "installationId"} {
		t.Run(name, func(t *testing.T) {
			var m map[string]json.RawMessage
			_ = json.Unmarshal(data, &m)
			delete(m, name)
			bad, _ := json.Marshal(m)
			var result LinuxBootEvidence
			if err := json.Unmarshal(bad, &result); err == nil {
				t.Fatal("accepted omitted measurement")
			}
		})
	}
	for _, name := range []string{"boundFolders", "matchedUsers", "bitlockerUnlocked", "bindings"} {
		t.Run("bridge/"+name, func(t *testing.T) {
			var m map[string]json.RawMessage
			_ = json.Unmarshal(data, &m)
			var bridge map[string]json.RawMessage
			_ = json.Unmarshal(m["bridge"], &bridge)
			delete(bridge, name)
			m["bridge"], _ = json.Marshal(bridge)
			bad, _ := json.Marshal(m)
			var result LinuxBootEvidence
			if err := json.Unmarshal(bad, &result); err == nil {
				t.Fatal("accepted omitted bridge measurement")
			}
		})
	}
}

func TestBootRecordRejectsTruncationAndOversize(t *testing.T) {
	p, e := bootEvidenceFixture()
	path := filepath.Join(t.TempDir(), "boot.json")
	data, _ := json.Marshal(e)
	for name, body := range map[string][]byte{"valid": data, "BOM": append([]byte("\ufeff"), data...), "truncated": data[:len(data)-1], "oversize": []byte(strings.Repeat(" ", 64*1024+1)), "trailing": append(append([]byte{}, data...), []byte("{}")...)} {
		t.Run(name, func(t *testing.T) {
			if err := os.WriteFile(path, body, 0600); err != nil {
				t.Fatal(err)
			}
			var result LinuxBootEvidence
			err := readBootRecord(path, &result)
			if name == "valid" || name == "BOM" {
				if err != nil {
					t.Fatal(err)
				}
				if err := validateLinuxBootEvidence(result, p, p.EspPartitionGuid, p.HostUUID); err != nil {
					t.Fatal(err)
				}
			} else if err == nil {
				t.Fatal("accepted invalid boot record")
			}
		})
	}
}

func TestInstallationIdentityIsFreshAndComplete(t *testing.T) {
	p, _ := bootEvidenceFixture()
	a, err := newInstallationIdentity(p.ImageRef, p.EspPartitionGuid, p.LoaderPath, p.HostUUID)
	if err != nil {
		t.Fatal(err)
	}
	b, err := newInstallationIdentity(p.ImageRef, p.EspPartitionGuid, p.LoaderPath, p.HostUUID)
	if err != nil {
		t.Fatal(err)
	}
	if a.InstallationID == b.InstallationID {
		t.Fatal("reused identity")
	}
	if _, err := newInstallationIdentity(p.ImageRef, "", p.LoaderPath, p.HostUUID); err == nil {
		t.Fatal("accepted absent ESP")
	}
	if _, err := newInstallationIdentity(p.ImageRef, p.EspPartitionGuid, p.LoaderPath, "12345678"); err == nil {
		t.Fatal("accepted truncated serial")
	}
}
