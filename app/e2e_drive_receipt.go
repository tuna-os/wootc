package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sync"
)

var e2eDriveWriteMu sync.Mutex
var e2eDirectiveID = regexp.MustCompile(`^[0-9a-f]{32}$`)

// Bind reports to the directive the frontend actually consumed.
func e2eUniqueObject(raw []byte) (map[string]json.RawMessage, error) {
	if len(raw) > 16384 {
		return nil, errors.New("oversized drive record")
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	t, err := d.Token()
	if err != nil || t != json.Delim('{') {
		return nil, errors.New("invalid drive object")
	}
	fields := map[string]json.RawMessage{}
	for d.More() {
		t, err = d.Token()
		if err != nil {
			return nil, err
		}
		key, ok := t.(string)
		if !ok {
			return nil, errors.New("invalid drive key")
		}
		if _, found := fields[key]; found {
			return nil, errors.New("duplicate drive key")
		}
		var value json.RawMessage
		if err = d.Decode(&value); err != nil {
			return nil, err
		}
		fields[key] = value
	}
	if _, err = d.Token(); err != nil {
		return nil, err
	}
	if _, err = d.Token(); err != io.EOF {
		return nil, errors.New("multiple drive records")
	}
	return fields, nil
}

func e2eBoundDriveReport(report, directive []byte) bool {
	r, err := e2eUniqueObject(report)
	if err != nil {
		return false
	}
	d, err := e2eUniqueObject(directive)
	if err != nil {
		return false
	}
	names := []string{"schemaVersion", "runId", "directiveId", "action", "screen", "installDriven", "installBtnDisabled", "hint", "progressStep", "error", "selectedRef", "imageMismatch"}
	if len(r) != len(names) {
		return false
	}
	for _, name := range names {
		if _, ok := r[name]; !ok {
			return false
		}
	}
	for _, fields := range []map[string]json.RawMessage{r, d} {
		if !bytes.Equal(fields["schemaVersion"], []byte("1")) {
			return false
		}
	}
	for _, name := range []string{"runId", "directiveId", "action"} {
		var observed, expected string
		if json.Unmarshal(r[name], &observed) != nil || json.Unmarshal(d[name], &expected) != nil || observed == "" || observed != expected {
			return false
		}
		if name == "directiveId" && !e2eDirectiveID.MatchString(observed) {
			return false
		}
		if name == "action" && observed != "install" && observed != "reboot" {
			return false
		}
	}
	return true
}

func writeE2EDriveReport(state string) {
	e2eDriveWriteMu.Lock()
	defer e2eDriveWriteMu.Unlock()
	directivePath := e2eDrivePath("e2e-drive.json")
	read := func(path string) ([]byte, error) {
		file, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		defer file.Close()
		raw, err := io.ReadAll(io.LimitReader(file, 16385))
		if err != nil || len(raw) > 16384 {
			return nil, errors.New("invalid drive file")
		}
		return raw, nil
	}
	directive, err := read(directivePath)
	if err != nil || !e2eBoundDriveReport([]byte(state), directive) {
		return
	}
	path := e2eDrivePath("e2e-drive-state.json")
	file, err := os.CreateTemp(filepath.Dir(path), ".wootc-drive-report-*")
	if err != nil {
		return
	}
	defer os.Remove(file.Name())
	if err = file.Chmod(0600); err == nil {
		_, err = file.WriteString(state)
	}
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil || closeErr != nil {
		return
	}
	current, err := read(directivePath)
	if err != nil || !bytes.Equal(current, directive) {
		return
	}
	_ = os.Rename(file.Name(), path)
}
