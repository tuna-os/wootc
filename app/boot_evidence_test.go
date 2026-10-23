package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const evidenceInstallationID = "0123456789abcdef0123456789abcdef"

// evidenceIdentity is install\installation.json for the install that
// evidenceFixture's boot belongs to.
func evidenceIdentity() InstallationIdentity {
	return InstallationIdentity{SchemaVersion: 1, InstallationID: evidenceInstallationID,
		ArmedAt: "2026-10-17T04:00:00Z", ImageRef: evidenceImage,
		EspPartitionGuid: "12345678-1234-5678-abcd-123456789abc", LoaderPath: `\EFI\fedora\shimx64.efi`,
		HostUUID: evidenceHost, RootDiskPath: "/wootc/disks/root.disk"}
}

// boundEvidence is the record the current collector writes: it names the
// installation and lists the bindings its bridge counts came from.
func boundEvidence(mutate func(map[string]any)) string {
	return evidenceFixture(func(v map[string]any) {
		v["installationId"] = evidenceInstallationID
		v["bridge"] = map[string]any{"boundFolders": 2, "matchedUsers": 1, "bitlockerUnlocked": true,
			"bindings": []map[string]any{
				{"source": "/run/wootc/bitlk-tmp/Users/A/Pictures", "target": "/home/a/Pictures", "user": "a"},
				{"source": "/run/wootc/bitlk-tmp/Users/A/Music", "target": "/home/a/Music", "user": "a"}}}
		if mutate != nil {
			mutate(v)
		}
	})
}

func boundInstall(t *testing.T, evidence string, identity *InstallationIdentity) string {
	t.Helper()
	withVolumeSerial(t, thisVolume, nil)
	root := evidenceInstall(t, evidence)
	if identity != nil {
		data, err := json.Marshal(identity)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "install", "installation.json"), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func TestFirstBootIsBoundToThisInstallation(t *testing.T) {
	identity := evidenceIdentity()
	got := assessFirstBootAt(boundInstall(t, boundEvidence(nil), &identity))
	if got.Verdict != FirstBootVerified || got.SourceImageRef != evidenceImage || got.Bridge == nil ||
		got.Bridge.BoundFolders != 2 || !got.Bridge.BitlockerUnlocked {
		t.Fatalf("got %+v", got)
	}
	// The status view repeats the counts, never the Windows paths behind them.
	data, _ := json.Marshal(got)
	if strings.Contains(string(data), "bitlk-tmp") || strings.Contains(string(data), "bindings") {
		t.Fatalf("assessment exposes bindings: %s", data)
	}
	accepted := map[string]func(map[string]any){
		"unrelated failed unit is reported, not judged": func(v map[string]any) { v["failedUnits"] = []string{"flatpak-preinstall.service"} },
		"undecodable boot entry is reported, not matched": func(v map[string]any) {
			v["bootCurrent"] = map[string]any{"source": "unavailable", "bootNumber": "0004"}
		},
	}
	for name, mutate := range accepted {
		t.Run(name, func(t *testing.T) {
			if got := assessFirstBootAt(boundInstall(t, boundEvidence(mutate), &identity)); got.Verdict != FirstBootVerified {
				t.Fatalf("got %+v", got)
			}
		})
	}
	refused := map[string]func(map[string]any){
		"another installation":  func(v map[string]any) { v["installationId"] = strings.Repeat("f", 32) },
		"no installation named": func(v map[string]any) { delete(v, "installationId") },
		"another ESP": func(v map[string]any) {
			nested(v, "bootCurrent")["espPartitionGuid"] = "aaaaaaaa-1234-5678-abcd-123456789abc"
		},
		"another loader":         func(v map[string]any) { nested(v, "bootCurrent")["loaderPath"] = `\EFI\Microsoft\Boot\bootmgfw.efi` },
		"before it was armed":    func(v map[string]any) { v["writtenAt"] = "2026-10-17T03:59:59Z" },
		"failed wootc unit":      func(v map[string]any) { v["failedUnits"] = []string{"wootc-passthrough.service"} },
		"no recorded selection":  func(v map[string]any) { delete(nested(v, "image"), "sourceRef") },
		"another host in record": func(v map[string]any) { nested(v, "rootDisk")["hostUuid"] = "1234567890ABCDEE" },
	}
	for name, mutate := range refused {
		t.Run(name, func(t *testing.T) {
			if got := assessFirstBootAt(boundInstall(t, boundEvidence(mutate), &identity)); got.Verdict != FirstBootMismatch {
				t.Fatalf("got %+v", got)
			}
		})
	}
	t.Run("identity names another host volume", func(t *testing.T) {
		other := evidenceIdentity()
		other.HostUUID = "1234567890ABCDEE"
		if got := assessFirstBootAt(boundInstall(t, boundEvidence(nil), &other)); got.Verdict != FirstBootMismatch {
			t.Fatalf("got %+v", got)
		}
	})
	t.Run("record names an installation this PC has no record of", func(t *testing.T) {
		if got := assessFirstBootAt(boundInstall(t, boundEvidence(nil), nil)); got.Verdict != FirstBootMismatch {
			t.Fatalf("got %+v", got)
		}
	})
	t.Run("unreadable identity is unverifiable", func(t *testing.T) {
		root := boundInstall(t, boundEvidence(nil), &identity)
		os.WriteFile(filepath.Join(root, "install", "installation.json"), []byte(`{"schemaVersion":1}`), 0o600)
		if got := assessFirstBootAt(root); got.Verdict != FirstBootUnverifiable {
			t.Fatalf("got %+v", got)
		}
	})
}

func TestFirstBootBindingsMustAccountForTheBridgeCounts(t *testing.T) {
	refused := map[string]func(map[string]any){
		"bound record without bindings": func(v map[string]any) { delete(nested(v, "bridge"), "bindings") },
		"folder count":                  func(v map[string]any) { nested(v, "bridge")["boundFolders"] = 3 },
		"user count":                    func(v map[string]any) { nested(v, "bridge")["matchedUsers"] = 0 },
		"target outside the user's home": func(v map[string]any) {
			nested(v, "bridge")["bindings"].([]map[string]any)[0]["target"] = "/home/b/Pictures"
		},
		"relative source": func(v map[string]any) {
			nested(v, "bridge")["bindings"].([]map[string]any)[0]["source"] = "Users/A/Pictures"
		},
		"repeated target": func(v map[string]any) {
			nested(v, "bridge")["bindings"].([]map[string]any)[1]["target"] = "/home/a/Pictures"
		},
		"unknown binding field": func(v map[string]any) {
			nested(v, "bridge")["bindings"].([]map[string]any)[0]["profile"] = "A"
		},
		"bindings not a list": func(v map[string]any) { nested(v, "bridge")["bindings"] = map[string]any{} },
	}
	for name, mutate := range refused {
		t.Run(name, func(t *testing.T) {
			if _, err := parseFirstBootEvidence([]byte(boundEvidence(mutate))); err == nil {
				t.Fatal("accepted inconsistent bridge evidence")
			}
		})
	}
	empty := boundEvidence(func(v map[string]any) {
		v["bridge"] = map[string]any{"boundFolders": 0, "matchedUsers": 0, "bitlockerUnlocked": false, "bindings": []any{}}
	})
	if _, err := parseFirstBootEvidence([]byte(empty)); err != nil {
		t.Fatalf("an empty bridge is a measurement: %v", err)
	}
}

func TestBootRecordRejectsTruncationAndOversize(t *testing.T) {
	data, _ := json.Marshal(evidenceIdentity())
	path := filepath.Join(t.TempDir(), "installation.json")
	for name, body := range map[string][]byte{"valid": data, "BOM": append([]byte("\ufeff"), data...), "truncated": data[:len(data)-1], "oversize": []byte(strings.Repeat(" ", 64*1024+1)), "trailing": append(append([]byte{}, data...), []byte("{}")...)} {
		t.Run(name, func(t *testing.T) {
			if err := os.WriteFile(path, body, 0600); err != nil {
				t.Fatal(err)
			}
			var result InstallationIdentity
			err := readBootRecord(path, &result)
			if name == "valid" || name == "BOM" {
				if err != nil {
					t.Fatal(err)
				}
				if err := validateInstallationIdentity(result); err != nil {
					t.Fatal(err)
				}
			} else if err == nil {
				t.Fatal("accepted invalid boot record")
			}
		})
	}
}

func TestInstallationIdentityIsFreshAndComplete(t *testing.T) {
	p := evidenceIdentity()
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
