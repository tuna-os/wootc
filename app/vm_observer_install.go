package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"
)

// The authenticated helper metadata must advertise this exact installer route.
// This capability concerns offline installation, never guest/desktop acceptance.
func observerBuilderSources(metadata []byte) (map[string]string, error) {
	if len(metadata) == 0 || len(metadata) > 64<<10 {
		return nil, fmt.Errorf("observer helper metadata unavailable")
	}
	duplicate := json.NewDecoder(bytes.NewReader(metadata))
	if err := qmpJSONValue(duplicate, 0); err != nil {
		return nil, fmt.Errorf("invalid observer helper metadata: %w", err)
	}
	if _, err := duplicate.Token(); err != io.EOF {
		return nil, fmt.Errorf("trailing observer helper metadata")
	}
	if _, err := parseVMStorageMinimums(metadata); err != nil {
		return nil, err
	}
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(metadata, &envelope); err != nil {
		return nil, err
	}
	for key := range envelope {
		if strings.EqualFold(key, "observerInstall") && key != "observerInstall" {
			return nil, fmt.Errorf("observer capability key must use exact spelling")
		}
	}
	observer := envelope["observerInstall"]
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(observer, &fields); err != nil {
		return nil, fmt.Errorf("invalid observer capability: %w", err)
	}
	allowed := map[string]bool{"mode": true, "accountModes": true, "sourceClosure": true, "targetPythonIsolated": true, "installationOnly": true, "sourceHashes": true}
	if len(fields) != len(allowed) {
		return nil, fmt.Errorf("observer capability fields differ")
	}
	for key := range fields {
		if !allowed[key] {
			return nil, fmt.Errorf("unknown observer capability field %q", key)
		}
	}

	var capability struct {
		Mode                 string            `json:"mode"`
		AccountModes         []string          `json:"accountModes"`
		SourceClosure        string            `json:"sourceClosure"`
		TargetPythonIsolated bool              `json:"targetPythonIsolated"`
		InstallationOnly     bool              `json:"installationOnly"`
		SourceHashes         map[string]string `json:"sourceHashes"`
	}
	decoder := json.NewDecoder(bytes.NewReader(observer))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&capability); err != nil {
		return nil, fmt.Errorf("observer installation capability absent or invalid: %w", err)
	}
	if capability.Mode != "boot-session-v1" || len(capability.AccountModes) != 1 || capability.AccountModes[0] != "create" || capability.SourceClosure != "/usr/lib/wootc-observer/closure.sha256" || !capability.TargetPythonIsolated || !capability.InstallationOnly {
		return nil, fmt.Errorf("unsupported observer installation capability")
	}

	if len(capability.SourceHashes) != 3 {
		return nil, fmt.Errorf("observer source closure absent")
	}
	digest := regexp.MustCompile(`^[a-f0-9]{64}$`)
	for _, name := range []string{"boot_probe.py", "wootc_ancestry.py", "wootc-observer.service"} {
		if !digest.MatchString(capability.SourceHashes[name]) {
			return nil, fmt.Errorf("observer source hash absent or invalid")
		}
	}
	return capability.SourceHashes, nil
}

func observerBuilderKernelArgs(metadata []byte, state *VMState) (string, error) {
	if state == nil {
		return "", fmt.Errorf("observer installation identity unavailable")
	}
	if _, err := observerBuilderSources(metadata); err != nil {
		return "", err
	}
	id := regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{7,63}$`)
	image := regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[a-f0-9]{64}$`)
	if !id.MatchString(state.RunID) || !id.MatchString(state.InstallID) || !image.MatchString(state.Image) {
		return "", fmt.Errorf("observer builder identity is invalid")
	}
	return "console=ttyS0 quiet wootc.image=" + state.Image + " wootc.run_id=" + state.RunID + " wootc.install_id=" + state.InstallID + " wootc.account_mode=create wootc.observer=boot-session-v1", nil
}
