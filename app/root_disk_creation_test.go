package main

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
)

func TestRootDiskCreationPreservesExistingData(t *testing.T) {
	for _, size := range []int64{4, 16} {
		root := t.TempDir()
		path := filepath.Join(root, "root.disk")
		original := []byte("existing Linux data")
		if err := os.WriteFile(path, original, 0600); err != nil {
			t.Fatal(err)
		}
		called := false
		if err := allocateNewRootDiskFile(path, size, func(string) error { called = true; return nil }); err == nil {
			t.Fatal("existing disk was accepted")
		}
		if called {
			t.Fatal("existing disk reached initializer")
		}
		after, err := os.ReadFile(path)
		if err != nil || string(after) != string(original) {
			t.Fatal("existing disk changed")
		}
	}
}

func TestRootDiskCreationRefusesEqualSizeImage(t *testing.T) {
	path := filepath.Join(t.TempDir(), "root.disk")
	if err := os.WriteFile(path, []byte("12345678"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := allocateNewRootDiskFile(path, 8, func(string) error { return nil }); err == nil {
		t.Fatal("size proxy authorized implicit reinstall")
	}
	after, err := os.ReadFile(path)
	if err != nil || string(after) != "12345678" {
		t.Fatal("equal-size Linux bytes changed")
	}
}

func TestRootDiskCreationRefusesDirectoryAndSymlink(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "root.disk")
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	if err := allocateNewRootDiskFile(path, 8, func(string) error { return nil }); err == nil {
		t.Fatal("directory accepted")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(root, "foreign")
	if err := os.WriteFile(target, []byte("foreign"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, path); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	if err := allocateNewRootDiskFile(path, 8, func(string) error { return nil }); err == nil {
		t.Fatal("symlink accepted")
	}
	after, err := os.ReadFile(target)
	if err != nil || string(after) != "foreign" {
		t.Fatal("symlink target changed")
	}
}

func TestRootDiskCreationAllocatesNewFileOnly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "disks", "root.disk")
	calls := 0
	if err := allocateNewRootDiskFile(path, 8192, func(p string) error {
		calls++
		if p != path {
			t.Fatal("wrong path")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil || st.Size() != 8192 || calls != 1 {
		t.Fatal("new image was not initialized exactly once")
	}
}

func TestRootDiskCreationRetainsNewFileOnInitializationFailure(t *testing.T) {
	path := filepath.Join(t.TempDir(), "root.disk")
	failure := errors.New("VDL initialization failed")
	err := allocateNewRootDiskFile(path, 8, func(string) error { return failure })
	if !errors.Is(err, failure) {
		t.Fatalf("lost initializer failure: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal("failed new file silently discarded")
	}
	if err := allocateNewRootDiskFile(path, 8, func(string) error { return nil }); err == nil {
		t.Fatal("failed allocation silently replaced")
	}
}

func TestRootDiskCreationInvalidSizeHasNoSideEffects(t *testing.T) {
	path := filepath.Join(t.TempDir(), "disks", "root.disk")
	if err := allocateNewRootDiskFile(path, 0, func(string) error { return nil }); err == nil {
		t.Fatal("invalid size accepted")
	}
	if _, err := os.Stat(filepath.Dir(path)); !os.IsNotExist(err) {
		t.Fatal("invalid request created files")
	}
}

func TestRootDiskCreationConcurrentCallsCannotReplaceWinner(t *testing.T) {
	path := filepath.Join(t.TempDir(), "root.disk")
	var initialized, successes atomic.Int32
	var workers sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < 16; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			<-start
			err := allocateNewRootDiskFile(path, 8, func(path string) error {
				initialized.Add(1)
				return os.WriteFile(path, []byte("LINUX123"), 0600)
			})
			if err == nil {
				successes.Add(1)
			}
		}()
	}
	close(start)
	workers.Wait()
	if initialized.Load() != 1 || successes.Load() != 1 {
		t.Fatalf("exclusive creation failed: initialized=%d successes=%d", initialized.Load(), successes.Load())
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "LINUX123" {
		t.Fatal("winner's bytes replaced")
	}
}

func TestRootDiskCreationRejectsImageAppearingAfterPreflight(t *testing.T) {
	path := filepath.Join(t.TempDir(), "root.disk")
	initialized := false
	err := allocateNewRootDiskFileWithOpen(path, 8, func(string) error { initialized = true; return nil }, func(path string, flags int, mode os.FileMode) (*os.File, error) {
		if err := os.WriteFile(path, []byte("FOREIGN!"), 0600); err != nil {
			return nil, err
		}
		return os.OpenFile(path, flags, mode)
	})
	if err == nil || initialized {
		t.Fatal("racing image was accepted or initialized")
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "FOREIGN!" {
		t.Fatal("racing existing image bytes changed")
	}
}
