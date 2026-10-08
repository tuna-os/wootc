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
	// A UTF-8 BOM prefix is not JSON whitespace: encoding/json rejects it,
	// and so would the frontend's JSON.parse. The harness wrote the install
	// directive with PowerShell 5.1 Set-Content -Encoding UTF8 (BOM) through
	// runs 36399679919/36413017019/36420437461, so the app saw no directive
	// and never reported while the harness readback — which decodes and
	// strips the BOM — kept passing. The writer is fixed to emit BOM-less
	// UTF-8; stripping here keeps any BOM'd producer from silently disabling
	// the drive loop again. Central: every drive-file parse enters here.
	raw = bytes.TrimPrefix(raw, []byte("\xef\xbb\xbf"))
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
	staged, ok := stageE2EFile(path, state)
	if !ok {
		return
	}
	current, err := read(directivePath)
	if err != nil || !bytes.Equal(current, directive) {
		os.Remove(staged)
		return
	}
	commitE2EFile(staged, path)
}

// stageE2EFile writes content to a temp file beside path. The caller
// re-validates whatever the write binds to, then commitE2EFile renames.
func stageE2EFile(path, content string) (string, bool) {
	file, err := os.CreateTemp(filepath.Dir(path), ".wootc-drive-report-*")
	if err != nil {
		return "", false
	}
	defer func() {
		if err != nil {
			os.Remove(file.Name())
		}
	}()
	if err = file.Chmod(0600); err == nil {
		_, err = file.WriteString(content)
	}
	if err == nil {
		err = file.Sync()
	}
	if err != nil {
		_ = file.Close()
		return "", false
	}
	if err = file.Close(); err != nil {
		return "", false
	}
	return file.Name(), true
}

func commitE2EFile(staged, path string) {
	defer os.Remove(staged)
	_ = os.Rename(staged, path)
}

// writeE2EReady persists the frontend's first-render signal. Unlike a drive
// report it binds to NO directive: readiness must be observable before the
// harness writes one (the install directive is only written after launch is
// confirmed, so waiting for a bound report first is a deadlock — GUI red,
// every run since the drive loop landed). The payload carries only the
// schema version and the current screen; progress authentication stays with
// the bound drive-state channel.
func writeE2EReady(state string) {
	fields, err := e2eUniqueObject([]byte(state))
	if err != nil || len(fields) != 2 {
		return
	}
	if !bytes.Equal(fields["schemaVersion"], []byte("1")) {
		return
	}
	screen, ok := fields["screen"]
	if !ok {
		return
	}
	var name string
	if json.Unmarshal(screen, &name) != nil || name == "" {
		return
	}
	if staged, ok := stageE2EFile(e2eDrivePath("e2e-ready.json"), state); ok {
		commitE2EFile(staged, e2eDrivePath("e2e-ready.json"))
	}
}
