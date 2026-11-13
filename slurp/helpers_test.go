package slurp

// Shared seams for the offline-pipeline tests. Each test gets its own
// Slurper (sl(t)) whose Runner is a recording fake, whose scratch and mount
// points are temp dirs, and whose scratch capacity observation fails until a
// test supplies one. No root, no NTFS partition and no /run access needed.

import (
	"errors"
	"io"
	"os"
	"strings"
	"sync"
	"testing"
)

// fakeRunner records Run calls and fails any call whose joined args contain
// a whole fail token (space-padded so "mount -t ntfs3" does not also match
// "mount -t ntfs-3g"). Output returns out/outErr.
type fakeRunner struct {
	failTokens []string
	calls      []string
	onRun      func(name string, args []string)
	out        []byte
	outErr     error
}

func (f *fakeRunner) Run(name string, args ...string) error {
	if f.onRun != nil {
		f.onRun(name, args)
	}
	joined := name + " " + strings.Join(args, " ")
	f.calls = append(f.calls, joined)
	padded := " " + joined + " "
	for _, tok := range f.failTokens {
		if strings.Contains(padded, " "+tok+" ") {
			return errors.New("mocked failure: " + tok)
		}
	}
	return nil
}

func (f *fakeRunner) Output(string, ...string) ([]byte, error) { return f.out, f.outErr }

var (
	slurpersMu sync.Mutex
	slurpers   = map[*testing.T]*Slurper{}
)

// sl returns the test's Slurper, creating it on first use.
func sl(t *testing.T) *Slurper {
	t.Helper()
	slurpersMu.Lock()
	defer slurpersMu.Unlock()
	if s, ok := slurpers[t]; ok {
		return s
	}
	s := NewSlurper(&fakeRunner{}, nil)
	s.Warnings = io.Discard
	s.ScratchBase = t.TempDir()
	s.MountPoint = t.TempDir()
	s.ScanMountPoint = t.TempDir()
	s.Available = func(string) (int64, error) { return 0, errors.New("no scratch capacity stubbed") }
	slurpers[t] = s
	t.Cleanup(func() {
		slurpersMu.Lock()
		delete(slurpers, t)
		slurpersMu.Unlock()
	})
	return s
}

func fake(t *testing.T) *fakeRunner {
	t.Helper()
	return sl(t).Runner.(*fakeRunner)
}

// stubOutput returns the given bytes for every Output call.
func stubOutput(t *testing.T, out []byte) {
	t.Helper()
	fake(t).out = out
}

// stubRun makes Run fail on the given whole tokens; returns a thunk yielding
// the recorded calls so far.
func stubRun(t *testing.T, failTokens ...string) func() []string {
	t.Helper()
	f := fake(t)
	f.failTokens = failTokens
	return func() []string { return f.calls }
}

// fakeRun is stubRun under the name the extraction tests use.
func fakeRun(t *testing.T, failTokens ...string) func() []string {
	t.Helper()
	return stubRun(t, failTokens...)
}

func withScanMountPoint(t *testing.T, dir string) {
	t.Helper()
	sl(t).ScanMountPoint = dir
}

// withScratchDirs returns the test Slurper's scratch base and mount point.
func withScratchDirs(t *testing.T) (scratch, mountPoint string) {
	t.Helper()
	s := sl(t)
	return s.ScratchBase, s.MountPoint
}

// fakeScratchCapacity replaces the scratch capacity observation so a test's
// data-migration budget does not depend on the host's /run. A non-nil err
// makes the observation fail. Returns a thunk for the observed paths.
func fakeScratchCapacity(t *testing.T, available int64, err error) func() []string {
	t.Helper()
	var paths []string
	sl(t).Available = func(path string) (int64, error) {
		paths = append(paths, path)
		if err != nil {
			return 0, err
		}
		return available, nil
	}
	return func() []string { return paths }
}

func mustWriteFile(t *testing.T, path string, data []byte, perm os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, data, perm); err != nil {
		t.Fatal(err)
	}
}
