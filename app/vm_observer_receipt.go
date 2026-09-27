package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
)

// The private builder channel proves offline installation only. Guest boot and
// desktop/editor observations remain separate, current-boot requirements.
func verifyVMObserverReceipt(input io.Reader, expected VMState, hashes map[string]string) (map[string]string, error) {
	limited := &io.LimitedReader{R: input, N: (64 << 20) + 1}
	scanner := bufio.NewScanner(limited)
	scanner.Buffer(make([]byte, 4096), 128<<10)
	observed, results, terminals := 0, 0, 0
	fields := []string{"schemaVersion", "action", "runId", "installId", "selectedDisk", "image", "sourceHashes", "labels", "targetDependencies", "offlineAncestry", "offlineBootAncestry", "persistenceConfiguration", "installed", "guestBootAccepted", "desktopQualified", "editorQualified"}
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if string(line) == "STATUS=SUCCESS" {
			terminals++
			if observed != 1 || results != 1 {
				return nil, fmt.Errorf("observer receipt absent before terminal")
			}
			continue
		}
		var kind struct {
			Action string `json:"action"`
			Type   string `json:"type"`
			Step   string `json:"step"`
		}
		if json.Unmarshal(line, &kind) != nil {
			continue
		}
		if kind.Step == "error" {
			return nil, fmt.Errorf("builder reported failure")
		}
		if kind.Type == "result" {
			results++
			if observed != 1 || terminals != 0 {
				return nil, fmt.Errorf("observer receipt absent before result")
			}
		}
		if kind.Action != "install-observer" {
			continue
		}
		observed++
		if observed != 1 || results != 0 || terminals != 0 {
			return nil, fmt.Errorf("duplicate or late observer receipt")
		}
		duplicate := json.NewDecoder(bytes.NewReader(line))
		if err := qmpJSONValue(duplicate, 0); err != nil {
			return nil, err
		}
		if _, err := duplicate.Token(); err != io.EOF {
			return nil, fmt.Errorf("trailing observer receipt")
		}
		var raw map[string]json.RawMessage
		if err := json.Unmarshal(line, &raw); err != nil {
			return nil, err
		}
		if len(raw) != len(fields) {
			return nil, fmt.Errorf("observer receipt fields differ")
		}
		for _, name := range fields {
			if _, ok := raw[name]; !ok {
				return nil, fmt.Errorf("observer receipt missing exact field %s", name)
			}
		}
		for name, value := range map[string]string{"schemaVersion": "1", "installed": "true", "guestBootAccepted": "false", "desktopQualified": "false", "editorQualified": "false"} {
			if string(bytes.TrimSpace(raw[name])) != value {
				return nil, fmt.Errorf("observer receipt scope/status differs")
			}
		}
		for name, value := range map[string]string{"action": "install-observer", "runId": expected.RunID, "installId": expected.InstallID, "selectedDisk": expected.DiskID, "image": expected.Image} {
			var got string
			if json.Unmarshal(raw[name], &got) != nil || got != value || value == "" {
				return nil, fmt.Errorf("observer receipt identity differs")
			}
		}
		var got map[string]string
		if json.Unmarshal(raw["sourceHashes"], &got) != nil || len(got) != 3 || len(hashes) != 3 {
			return nil, fmt.Errorf("observer receipt source closure absent")
		}
		for _, name := range []string{"boot_probe.py", "wootc_ancestry.py", "wootc-observer.service"} {
			if hashes[name] == "" || got[name] != hashes[name] {
				return nil, fmt.Errorf("installed observer source differs from authenticated runtime")
			}
		}
		for _, name := range []string{"labels", "targetDependencies", "offlineAncestry", "offlineBootAncestry", "persistenceConfiguration"} {
			var value map[string]json.RawMessage
			if json.Unmarshal(raw[name], &value) != nil || len(value) == 0 {
				return nil, fmt.Errorf("observer installation facts absent")
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if limited.N == 0 || observed != 1 || results != 1 || terminals != 1 {
		return nil, fmt.Errorf("one completed observer installation required")
	}
	copied := map[string]string{}
	for k, v := range hashes {
		copied[k] = v
	}
	return copied, nil
}
