package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Persisted observations cannot use JSON's last-key-wins or case-insensitive
// field matching: either can replace a failed attempt with a healthy one.
func decodeStrictStatusRecord(data []byte, target any, fields map[string]string, required []string) error {
	data = bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf})
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return fmt.Errorf("status record must be an object")
	}
	seen := map[string]bool{}
	for decoder.More() {
		token, err = decoder.Token()
		key, ok := token.(string)
		kind, known := fields[key]
		if err != nil || !ok || seen[key] || !known {
			return fmt.Errorf("ambiguous or unsupported status field %q", key)
		}
		seen[key] = true
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return err
		}
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return fmt.Errorf("null status field %q", key)
		}
		switch kind {
		case "string":
			var text string
			err = json.Unmarshal(value, &text)
		case "bool":
			var flag bool
			err = json.Unmarshal(value, &flag)
		case "strings":
			var lines []string
			err = json.Unmarshal(value, &lines)
		default:
			return fmt.Errorf("unsupported status field contract")
		}
		if err != nil {
			return fmt.Errorf("invalid status field %q: %w", key, err)
		}
	}
	if _, err := decoder.Token(); err != nil {
		return err
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return fmt.Errorf("trailing status record data")
	}
	for _, key := range required {
		if !seen[key] {
			return fmt.Errorf("missing status field %q", key)
		}
	}
	return json.Unmarshal(data, target)
}

func readBoundedStatusRecord(path string) ([]byte, error) {
	before, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !before.Mode().IsRegular() || before.Size() > 64*1024 {
		return nil, fmt.Errorf("status record is not a bounded regular file")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !opened.Mode().IsRegular() || !os.SameFile(before, opened) {
		return nil, fmt.Errorf("status record identity changed")
	}
	data, err := io.ReadAll(io.LimitReader(f, 64*1024+1))
	if err != nil {
		return nil, err
	}
	if len(data) > 64*1024 {
		return nil, fmt.Errorf("status record exceeds size limit")
	}
	return data, nil
}

func readNativeStartupLifecycle(root string) (LifecycleState, error) {
	state, err := loadStatusState(filepath.Join(root, "state.json"))
	if os.IsNotExist(err) && !hasInstallAttempt(root) {
		return LifecycleState{}, nil
	}
	return state, err
}

func readNativeStartupRecovery(root string) (RecoveryVerdict, error) {
	data, err := readBoundedStatusRecord(filepath.Join(root, "install", "recovery-verdict.json"))
	if os.IsNotExist(err) {
		return RecoveryVerdict{}, nil
	}
	if err != nil {
		return RecoveryVerdict{}, err
	}
	var verdict RecoveryVerdict
	fields := map[string]string{"phaseId": "string", "verdict": "string", "phase": "string", "title": "string", "message": "string", "details": "string", "logTail": "strings", "untouched": "bool", "canTryAgain": "bool", "canRemove": "bool", "canRepairBoot": "bool", "timestamp": "string"}
	if err := decodeStrictStatusRecord(data, &verdict, fields, []string{"verdict", "title", "message", "untouched", "canTryAgain", "canRemove", "canRepairBoot", "timestamp"}); err != nil {
		return RecoveryVerdict{}, err
	}
	switch verdict.Verdict {
	case VerdictNeverBooted, VerdictInterrupted, VerdictFailed, VerdictDeployed, VerdictHealthy:
	default:
		return RecoveryVerdict{}, fmt.Errorf("unsupported recovery verdict")
	}
	if strings.TrimSpace(verdict.Title) == "" {
		return RecoveryVerdict{}, fmt.Errorf("missing recovery title")
	}
	if _, err := time.Parse(time.RFC3339, verdict.Timestamp); err != nil {
		return RecoveryVerdict{}, fmt.Errorf("invalid recovery timestamp: %w", err)
	}
	return verdict, nil
}
