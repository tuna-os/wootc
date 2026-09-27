//go:build !windows

package main

import (
	"bytes"
	"encoding/json"
	"os/exec"
	"strings"
	"testing"
)

func TestObserverActualInstallerPrivateEmissionAndHostReceipt(t *testing.T) {
	command := exec.Command("python3", "-I", "-S", "-B", "../tests/unit/vm_observer_receipt_fixture.py")
	raw, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("actual controlled installer/emit: %v %s", err, raw)
	}
	expected := VMState{RunID: "run_test123", InstallID: "install_test123", Image: "ghcr.io/example/image@sha256:" + strings.Repeat("a", 64), DiskID: "11111111-1111-1111-1111-111111111111"}
	hashes, err := observerBuilderSources(observerTestMetadata(t))
	if err != nil {
		t.Fatal(err)
	}
	result := []byte("{\"type\":\"result\"}\nSTATUS=SUCCESS\n")
	stream := append(append([]byte{}, raw...), result...)
	if _, err = verifyVMObserverReceipt(bytes.NewReader(stream), expected, hashes); err != nil {
		t.Fatal(err)
	}
	var record map[string]interface{}
	if err = json.Unmarshal(bytes.TrimSpace(raw), &record); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"runId", "installId", "selectedDisk", "image", "sourceHashes", "installed", "guestBootAccepted", "labels", "offlineAncestry", "offlineBootAncestry", "targetDependencies"} {
		t.Run(field, func(t *testing.T) {
			altered := map[string]interface{}{}
			for k, v := range record {
				altered[k] = v
			}
			altered[field] = nil
			bad, err := json.Marshal(altered)
			if err != nil {
				t.Fatal(err)
			}
			bad = append(append(bad, '\n'), result...)
			if _, err = verifyVMObserverReceipt(bytes.NewReader(bad), expected, hashes); err == nil {
				t.Fatalf("invalid %s accepted", field)
			}
		})
	}
	for _, field := range []string{"labels", "targetDependencies", "offlineAncestry", "offlineBootAncestry", "persistenceConfiguration"} {
		t.Run("invalidAudit_"+field, func(t *testing.T) {
			altered := map[string]interface{}{}
			for k, v := range record {
				altered[k] = v
			}
			altered[field] = map[string]interface{}{"valid": false}
			bad, _ := json.Marshal(altered)
			bad = append(append(bad, '\n'), result...)
			if _, err = verifyVMObserverReceipt(bytes.NewReader(bad), expected, hashes); err == nil {
				t.Fatal("invalid nonempty offline audit accepted")
			}
		})
	}
	for _, name := range []string{"disabledRequiresLabels", "differentRootBootDisk", "foreignDependency", "persistentVarUnknown"} {
		t.Run(name, func(t *testing.T) {
			var altered map[string]interface{}
			_ = json.Unmarshal(bytes.TrimSpace(raw), &altered)
			switch name {
			case "disabledRequiresLabels":
				altered["labels"].(map[string]interface{})["labelsRequired"] = true
			case "differentRootBootDisk":
				altered["offlineBootAncestry"].(map[string]interface{})["selectedDiskDevice"] = "/dev/vdb"
			case "foreignDependency":
				altered["targetDependencies"].(map[string]interface{})["mappedDependencies"] = []string{"/var/home/user/library.so"}
			case "persistentVarUnknown":
				altered["persistenceConfiguration"].(map[string]interface{})["varPersistent"] = false
			}
			bad, _ := json.Marshal(altered)
			bad = append(append(bad, '\n'), result...)
			if _, err = verifyVMObserverReceipt(bytes.NewReader(bad), expected, hashes); err == nil {
				t.Fatal("contradictory offline audit accepted")
			}
		})
	}
	for name, input := range map[string][]byte{
		"absent": result, "duplicate": append(append(append([]byte{}, raw...), raw...), result...),
		"late":            append(append([]byte{}, result...), raw...),
		"missingTerminal": append(append([]byte{}, raw...), []byte("{\"type\":\"result\"}\n")...),
		"extraTerminal":   append(append([]byte{}, stream...), []byte("STATUS=SUCCESS\n")...),
		"caseAlias":       bytes.Replace(stream, []byte(`"installed": true`), []byte(`"Installed": true`), 1),
		"claimedDesktop":  bytes.Replace(stream, []byte(`"desktopQualified": false`), []byte(`"desktopQualified": true`), 1),
		"failure":         append(append([]byte{}, stream...), []byte("{\"step\":\"error\"}\n")...),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err = verifyVMObserverReceipt(bytes.NewReader(input), expected, hashes); err == nil {
				t.Fatal("invalid private channel receipt accepted")
			}
		})
	}
	foreign := map[string]string{}
	for name, value := range hashes {
		foreign[name] = value
	}
	foreign["boot_probe.py"] = strings.Repeat("f", 64)
	if _, err = verifyVMObserverReceipt(bytes.NewReader(stream), expected, foreign); err == nil {
		t.Fatal("foreign authenticated source accepted")
	}
}
