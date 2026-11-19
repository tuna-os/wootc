//go:build linux

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/syndtr/goleveldb/leveldb"
)

func TestSessionRollbackPreservesConcurrentCookieWrites(t *testing.T) {
	for _, mode := range []string{"native-edit", "sqlite-wal", "shm-only", "replaced-inode"} {
		t.Run(mode, func(t *testing.T) {
			dir := t.TempDir()
			target, prepared := filepath.Join(dir, "Cookies"), filepath.Join(dir, "original-backup")
			writeSessionCookieFixture(t, target, 24)
			writeSessionCookieFixture(t, prepared, 24, sessionCookieFixture{host: "example.test", name: "imported", encrypted: []byte("fixture-ciphertext")})
			original, err := os.ReadFile(target)
			if err != nil {
				t.Fatal(err)
			}
			digest, err := sessionStoreDigest(target)
			if err != nil {
				t.Fatal(err)
			}
			r := &sessionReplacement{target: target, prepared: prepared, originalDigest: digest}
			if err := r.install(); err != nil {
				t.Fatal(err)
			}
			db, err := openSessionSQLite(target, false)
			if err != nil {
				t.Fatal(err)
			}
			if mode == "sqlite-wal" {
				if _, err := db.Exec(`PRAGMA journal_mode=WAL`); err != nil {
					t.Fatal(err)
				}
			}
			if mode == "native-edit" || mode == "sqlite-wal" {
				if _, err := db.Exec(`INSERT INTO meta VALUES('native-edit','must-survive')`); err != nil {
					t.Fatal(err)
				}
			}
			if mode != "sqlite-wal" {
				db.Close()
			} else {
				defer db.Close()
			}
			if mode == "shm-only" {
				if err := os.WriteFile(target+"-shm", []byte("native-shared-state"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if mode == "replaced-inode" {
				data, err := os.ReadFile(target)
				if err != nil {
					t.Fatal(err)
				}
				other := filepath.Join(dir, "native-replacement")
				if err := os.WriteFile(other, data, 0o600); err != nil {
					t.Fatal(err)
				}
				if err := os.Rename(other, target); err != nil {
					t.Fatal(err)
				}
			}
			current, err := os.ReadFile(target)
			if err != nil {
				t.Fatal(err)
			}
			sidecars := make(map[string][]byte)
			for _, suffix := range []string{"-wal", "-shm"} {
				if data, err := os.ReadFile(target + suffix); err == nil {
					sidecars[suffix] = data
				}
			}
			// A later store fails before publication; the first store must not
			// destroy any state written by the browser after it was installed.
			secondTarget, secondPrepared := filepath.Join(dir, "second"), filepath.Join(dir, "second-new")
			if err := os.WriteFile(secondTarget, []byte("before"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(secondPrepared, []byte("staged"), 0o600); err != nil {
				t.Fatal(err)
			}
			secondDigest, err := sessionStoreDigest(secondTarget)
			if err != nil {
				t.Fatal(err)
			}
			second := &sessionReplacement{target: secondTarget, prepared: secondPrepared, originalDigest: secondDigest}
			if err := os.WriteFile(secondTarget, []byte("concurrent change"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := second.install(); err == nil {
				t.Fatal("forced later-store failure did not occur")
			}
			rollbackErr := r.rollback()
			r.discard()
			second.discard()
			if rollbackErr == nil {
				t.Error("rollback accepted concurrent browser state")
			}
			after, err := os.ReadFile(target)
			if err != nil || !bytes.Equal(current, after) {
				t.Error("rollback lost current cookie database")
			}
			backup, err := os.ReadFile(prepared)
			if err != nil || !bytes.Equal(original, backup) {
				t.Error("rollback lost original cookie backup")
			}
			for suffix, expected := range sidecars {
				after, err := os.ReadFile(target + suffix)
				if err != nil || !bytes.Equal(expected, after) {
					t.Errorf("rollback changed %s sidecar", suffix)
				}
			}
		})
	}
}

func TestSessionRollbackPreservesConcurrentLevelDBWrites(t *testing.T) {
	dir := t.TempDir()
	target, prepared := filepath.Join(dir, "leveldb"), filepath.Join(dir, "original-backup")
	writeSessionLocalFixture(t, target, map[string][]byte{"original": []byte("keep")})
	writeSessionLocalFixture(t, prepared, map[string][]byte{"imported": []byte("fixture")})
	original, err := sessionStoreDigest(target)
	if err != nil {
		t.Fatal(err)
	}
	r := &sessionReplacement{target: target, prepared: prepared, originalDigest: original}
	if err := r.install(); err != nil {
		t.Fatal(err)
	}
	db, err := leveldb.OpenFile(target, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Put([]byte("native-edit"), []byte("must-survive"), nil); err != nil {
		t.Fatal(err)
	}
	db.Close()
	current, err := sessionStoreDigest(target)
	if err != nil {
		t.Fatal(err)
	}
	rollbackErr := r.rollback()
	r.discard()
	if rollbackErr == nil {
		t.Error("rollback accepted changed LevelDB")
	}
	if after, err := sessionStoreDigest(target); err != nil || after != current {
		t.Error("rollback lost current LevelDB state")
	}
	if backup, err := sessionStoreDigest(prepared); err != nil || backup != original {
		t.Error("rollback lost original LevelDB backup")
	}
}

func TestSessionRollbackRetainsPublishedFileDescriptors(t *testing.T) {
	for _, directoryStore := range []bool{false, true} {
		t.Run(map[bool]string{false: "file", true: "directory"}[directoryStore], func(t *testing.T) {
			dir := t.TempDir()
			target, prepared := filepath.Join(dir, "live"), filepath.Join(dir, "backup")
			liveFile, preparedFile := target, prepared
			if directoryStore {
				if err := os.Mkdir(target, 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(prepared, 0o700); err != nil {
					t.Fatal(err)
				}
				liveFile, preparedFile = filepath.Join(target, "record"), filepath.Join(prepared, "record")
			}
			if err := os.WriteFile(liveFile, []byte("original"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(preparedFile, []byte("imported"), 0o600); err != nil {
				t.Fatal(err)
			}
			digest, err := sessionStoreDigest(target)
			if err != nil {
				t.Fatal(err)
			}
			r := &sessionReplacement{target: target, prepared: prepared, originalDigest: digest}
			if err := r.install(); err != nil {
				t.Fatal(err)
			}
			// An already-open descriptor can write after the rollback's
			// fingerprint/exchange. Never delete its displaced inode/store.
			native, err := os.OpenFile(liveFile, os.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			defer native.Close()
			if err := r.rollback(); err != nil {
				t.Fatal(err)
			}
			if _, err := native.WriteAt([]byte("new-edit"), 0); err != nil {
				t.Fatal(err)
			}
			if err := native.Sync(); err != nil {
				t.Fatal(err)
			}
			r.discard()
			current, err := os.ReadFile(liveFile)
			if err != nil || string(current) != "original" {
				t.Fatal("ordinary rollback did not restore original")
			}
			displaced, err := os.ReadFile(preparedFile)
			if err != nil || string(displaced) != "new-edit" {
				t.Fatal("cleanup deleted a published store containing a late native edit")
			}
		})
	}
}
