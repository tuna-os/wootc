package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
)

// The authenticated helper metadata must advertise this exact installer route.
// This capability concerns offline installation, never guest/desktop acceptance.
func observerBuilderKernelArgs(metadata []byte, state *VMState) (string, error) {
	if len(metadata) == 0 || len(metadata) > 64<<10 || state == nil {
		return "", fmt.Errorf("observer helper metadata unavailable")
	}
	duplicate := json.NewDecoder(bytes.NewReader(metadata))
	if err := qmpJSONValue(duplicate, 0); err != nil {
		return "", fmt.Errorf("invalid observer helper metadata: %w", err)
	}
	if _, err := duplicate.Token(); err != io.EOF {
		return "", fmt.Errorf("trailing observer helper metadata")
	}
	if _, err := parseVMStorageMinimums(metadata); err != nil {
		return "", err
	}
	var envelope struct {
		Observer json.RawMessage `json:"observerInstall"`
	}
	if err := json.Unmarshal(metadata, &envelope); err != nil {
		return "", err
	}
	var capability struct {
		Mode                 string   `json:"mode"`
		AccountModes         []string `json:"accountModes"`
		SourceClosure        string   `json:"sourceClosure"`
		TargetPythonIsolated bool     `json:"targetPythonIsolated"`
		InstallationOnly     bool     `json:"installationOnly"`
	}
	decoder := json.NewDecoder(bytes.NewReader(envelope.Observer))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&capability); err != nil {
		return "", fmt.Errorf("observer installation capability absent or invalid: %w", err)
	}
	if capability.Mode != "boot-session-v1" || len(capability.AccountModes) != 1 || capability.AccountModes[0] != "create" || capability.SourceClosure != "/usr/lib/wootc-observer/closure.sha256" || !capability.TargetPythonIsolated || !capability.InstallationOnly {
		return "", fmt.Errorf("unsupported observer installation capability")
	}
	id := regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{7,63}$`)
	image := regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[a-f0-9]{64}$`)
	if !id.MatchString(state.RunID) || !id.MatchString(state.InstallID) || !image.MatchString(state.Image) {
		return "", fmt.Errorf("observer builder identity is invalid")
	}
	return "console=ttyS0 quiet wootc.image=" + state.Image + " wootc.run_id=" + state.RunID + " wootc.install_id=" + state.InstallID + " wootc.account_mode=create wootc.observer=boot-session-v1", nil
}
