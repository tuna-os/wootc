//go:build linux

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const stagedSessionDirectory = "/run/wootc/host/wootc/install/slurp/session"

// sessionEnvelopeStore deliberately has no fallback to installed/share copies:
// the Windows volume retains the encrypted originals and is never modified here.
type sessionEnvelopeStore struct {
	root   *os.Root
	staged map[string]SessionExport
}

func supportedSessionApp(app string) bool {
	return app == "chrome" || app == "edge" || app == "spotify"
}

func openSessionEnvelopeStore(directory string) (*sessionEnvelopeStore, error) {
	if err := safeSessionPath(directory); err != nil {
		return nil, errors.New("staged session directory is missing or traverses a symbolic link")
	}
	root, err := os.OpenRoot(directory)
	if err != nil {
		return nil, errors.New("staged session directory is unavailable")
	}
	store := &sessionEnvelopeStore{root: root, staged: make(map[string]SessionExport)}
	data, err := store.readFile("exports.json", 64*1024)
	if err != nil {
		root.Close()
		return nil, errors.New("session export ledger is unavailable")
	}
	var entries []SessionExport
	if err := json.Unmarshal(data, &entries); err != nil {
		root.Close()
		return nil, errors.New("session export ledger is invalid")
	}
	seen := make(map[string]bool)
	for _, entry := range entries {
		if !supportedSessionApp(entry.App) {
			continue
		}
		if seen[entry.App] {
			root.Close()
			return nil, errors.New("session export ledger contains duplicate applications")
		}
		seen[entry.App] = true
		// An exporter is not an authentication verifier, even if its ledger
		// claims otherwise. Only explicitly staged entries are consumable.
		if entry.State == "staged" {
			store.staged[entry.App] = entry
		}
	}
	return store, nil
}

func (s *sessionEnvelopeStore) readFile(name string, maximum int64) ([]byte, error) {
	if filepath.Base(name) != name || name == "." || name == ".." {
		return nil, errors.New("invalid session filename")
	}
	info, err := s.root.Lstat(name)
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("session input must be a regular file, not a symbolic link")
	}
	f, err := s.root.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !os.SameFile(info, opened) || opened.Size() > maximum {
		return nil, errors.New("session input changed or exceeds its size limit")
	}
	data, err := io.ReadAll(io.LimitReader(f, maximum+1))
	if err != nil || int64(len(data)) > maximum {
		return nil, errors.New("cannot read bounded session input")
	}
	return data, nil
}

func (s *sessionEnvelopeStore) unlock(app string, consent bool, secret []byte) ([]byte, error) {
	if !supportedSessionApp(app) {
		return nil, errors.New("application is not eligible for session import")
	}
	if !consent {
		return nil, errors.New("session import requires explicit per-app consent")
	}
	if _, ok := s.staged[app]; !ok {
		return nil, errors.New("application has no staged session envelope")
	}
	blob, err := s.readFile(app+".enc", 4096)
	if err != nil {
		return nil, fmt.Errorf("cannot read staged %s envelope", app)
	}
	key, err := openSessionPayload(secret, app, blob)
	if err != nil {
		return nil, errors.New("cannot unlock session: wrong password, damaged envelope, or unsupported envelope version")
	}
	if len(key) != 32 {
		clear(key)
		return nil, errors.New("staged envelope does not contain a supported Windows os_crypt key")
	}
	return key, nil
}
