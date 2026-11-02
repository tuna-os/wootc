//go:build linux

package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/syndtr/goleveldb/leveldb"
	"github.com/syndtr/goleveldb/leveldb/opt"
)

func writeSessionLocalFixture(t *testing.T, directory string, records map[string][]byte) {
	t.Helper()
	db, err := leveldb.OpenFile(directory, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	batch := new(leveldb.Batch)
	batch.Put([]byte("VERSION"), []byte("1"))
	for key, value := range records {
		batch.Put([]byte(key), value)
	}
	if err := db.Write(batch, &opt.WriteOptions{Sync: true}); err != nil {
		t.Fatal(err)
	}
}

func TestChromiumLocalStorageBytePreservingOriginMergeAndRollback(t *testing.T) {
	dir := t.TempDir()
	source, target := filepath.Join(dir, "WindowsLevelDB"), filepath.Join(dir, "LinuxLevelDB")
	// Includes opaque records and binary UTF-16-style script data. None are
	// guessed to be encrypted: Chromium's generic store has no such contract.
	writeSessionLocalFixture(t, source, map[string][]byte{
		"_https://new.example\x00\x01key":      {0, 0xff, 0, 0x76},
		"META:https://new.example":             {8, 1},
		"_https://existing.example\x00\x01key": []byte("do-not-overwrite"),
		"META:https://existing.example":        {8, 2},
		"UNKNOWN-opaque-record":                {0xff, 0, 1, 2},
	})
	writeSessionLocalFixture(t, target, map[string][]byte{
		"_https://existing.example\x00\x01key": []byte("user-linux-edit"),
		"META:https://existing.example":        {8, 99},
		"LOCAL-unknown":                        {9, 0, 8},
	})
	sourceBefore, err := sessionStoreDigest(source)
	if err != nil {
		t.Fatal(err)
	}
	targetBefore, err := sessionStoreDigest(target)
	if err != nil {
		t.Fatal(err)
	}
	replacement, counts, err := prepareChromiumLocalStorage(context.Background(), source, target)
	if err != nil {
		t.Fatal(err)
	}
	defer replacement.discard()
	if counts.Written != 3 || counts.Preserved != 2 {
		t.Fatalf("unexpected merge counts %#v", counts)
	}
	if digest, err := sessionStoreDigest(target); err != nil || digest != targetBefore {
		t.Fatal("prepare changed target bytes")
	}
	if err := replacement.install(); err != nil {
		t.Fatal(err)
	}
	db, err := leveldb.OpenFile(target, &opt.Options{ReadOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	for key, want := range map[string][]byte{
		"_https://new.example\x00\x01key":      {0, 0xff, 0, 0x76},
		"_https://existing.example\x00\x01key": []byte("user-linux-edit"),
		"META:https://existing.example":        {8, 99},
		"UNKNOWN-opaque-record":                {0xff, 0, 1, 2},
		"LOCAL-unknown":                        {9, 0, 8},
	} {
		got, err := db.Get([]byte(key), nil)
		if err != nil || !bytes.Equal(got, want) {
			t.Fatalf("record %q did not preserve bytes", key)
		}
	}
	db.Close()
	second, counts, err := prepareChromiumLocalStorage(context.Background(), source, target)
	if err != nil {
		t.Fatal(err)
	}
	defer second.discard()
	if counts.Written != 0 {
		t.Fatal("repeat merge rewrote existing origins/unknown keys")
	}
	if err := replacement.rollback(); err != nil {
		t.Fatal(err)
	}
	if digest, err := sessionStoreDigest(target); err != nil || digest != targetBefore {
		t.Fatal("rollback did not restore exact store bytes")
	}
	if digest, err := sessionStoreDigest(source); err != nil || digest != sourceBefore {
		t.Fatal("source store modified")
	}
}

func TestChromiumLocalStorageUnsupportedAndUnsafeSourceFailClosed(t *testing.T) {
	for _, mode := range []string{"unsupported-version", "symlink", "canceled"} {
		t.Run(mode, func(t *testing.T) {
			dir := t.TempDir()
			source, target := filepath.Join(dir, "source"), filepath.Join(dir, "target")
			writeSessionLocalFixture(t, source, map[string][]byte{"_https://example.com\x00\x01key": []byte("script-value")})
			writeSessionLocalFixture(t, target, map[string][]byte{"local": []byte("keep")})
			if mode == "unsupported-version" {
				db, err := leveldb.OpenFile(source, nil)
				if err != nil {
					t.Fatal(err)
				}
				if err := db.Put([]byte("VERSION"), []byte("99"), nil); err != nil {
					t.Fatal(err)
				}
				db.Close()
			}
			if mode == "symlink" {
				if err := os.Symlink(filepath.Join(target, "CURRENT"), filepath.Join(source, "unsafe")); err != nil {
					t.Fatal(err)
				}
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if mode == "canceled" {
				cancel()
			}
			before, err := sessionStoreDigest(target)
			if err != nil {
				t.Fatal(err)
			}
			if replacement, _, err := prepareChromiumLocalStorage(ctx, source, target); err == nil {
				replacement.discard()
				t.Fatal("unsafe/unsupported source accepted")
			}
			if digest, err := sessionStoreDigest(target); err != nil || digest != before {
				t.Fatal("failed import changed target")
			}
		})
	}
}

func TestSessionTargetProfilesAreNotArbitraryPaths(t *testing.T) {
	for _, name := range []string{"Default", "Profile 1", "Profile 12"} {
		if !sessionProfileName(name) {
			t.Errorf("valid profile refused: %q", name)
		}
	}
	for _, name := range []string{"", "../Default", "/etc", "Profile ", "Profile ../x", "Profile 1/../2", "Profile -1"} {
		if sessionProfileName(name) {
			t.Errorf("unsafe profile accepted: %q", name)
		}
	}
}
