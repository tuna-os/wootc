//go:build linux

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/syndtr/goleveldb/leveldb"
	"github.com/syndtr/goleveldb/leveldb/opt"
)

func sessionStoreDigest(path string) ([32]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return [32]byte{}, err
	}
	if info.Mode().IsRegular() {
		return sessionFileDigest(path)
	}
	if !info.IsDir() {
		return [32]byte{}, errors.New("unsupported session store type")
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		return [32]byte{}, err
	}
	defer root.Close()
	h := sha256.New()
	err = filepath.WalkDir(path, func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return errors.New("session store contains a symbolic link")
		}
		if entry.IsDir() {
			return nil
		}
		if !entry.Type().IsRegular() {
			return errors.New("session store contains a special file")
		}
		rel, err := filepath.Rel(path, name)
		if err != nil {
			return err
		}
		h.Write([]byte(rel))
		h.Write([]byte{0})
		f, err := root.Open(rel)
		if err != nil {
			return err
		}
		defer f.Close()
		fileHash := sha256.New()
		if _, err := io.Copy(fileHash, f); err != nil {
			return err
		}
		digest := fileHash.Sum(nil)
		h.Write(digest)
		return nil
	})
	var digest [32]byte
	copy(digest[:], h.Sum(nil))
	return digest, err
}

func copySessionDirectory(source, target string) error {
	if err := safeSessionPath(source); err != nil {
		return err
	}
	root, err := os.OpenRoot(source)
	if err != nil {
		return err
	}
	defer root.Close()
	return filepath.WalkDir(source, func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(source, name)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		dest := filepath.Join(target, rel)
		if entry.IsDir() {
			return os.Mkdir(dest, 0o700)
		}
		if !entry.Type().IsRegular() {
			return errors.New("session store contains a symbolic link or special file")
		}
		input, err := root.Open(rel)
		if err != nil {
			return err
		}
		defer input.Close()
		output, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(output, input)
		syncErr := output.Sync()
		closeErr := output.Close()
		if copyErr != nil {
			return copyErr
		}
		if syncErr != nil {
			return syncErr
		}
		return closeErr
	})
}

// Chromium Local Storage is script-controlled data, NOT a generic os_crypt
// value container. Its VERSION=1 records and metadata are documented upstream
// in local_storage_impl.cc. Applying AES to all values corrupts them. Transfer
// bytes unchanged and preserve complete existing target origins (including
// their metadata). App-specific encrypted tokens, including Spotify layouts,
// cannot be recognized safely without a verified application record schema.
func localStorageOrigin(key []byte) string {
	if bytes.HasPrefix(key, []byte("METAACCESS:")) {
		return string(key[len("METAACCESS:"):])
	}
	if bytes.HasPrefix(key, []byte("META:")) {
		return string(key[len("META:"):])
	}
	if len(key) > 1 && key[0] == '_' {
		if end := bytes.IndexByte(key[1:], 0); end >= 0 {
			return string(key[1 : 1+end])
		}
	}
	return ""
}

func prepareChromiumLocalStorage(ctx context.Context, source, target string) (_ *sessionReplacement, counts sessionRewriteCounts, resultErr error) {
	for _, path := range []string{source, target} {
		if err := safeSessionPath(path); err != nil {
			return nil, counts, err
		}
	}
	sourceDigest, err := sessionStoreDigest(source)
	if err != nil {
		return nil, counts, errors.New("cannot snapshot source Local Storage")
	}
	targetDigest, err := sessionStoreDigest(target)
	if err != nil {
		return nil, counts, errors.New("cannot snapshot target Local Storage")
	}
	// Open only copies. Even a read-only third-party LevelDB opener may touch
	// its lock/log files; Windows stores must remain byte-for-byte unchanged.
	sourceCopy, err := os.MkdirTemp(filepath.Dir(target), ".wootc-session-source-*")
	if err != nil {
		return nil, counts, errors.New("cannot create private Local Storage staging directory")
	}
	defer os.RemoveAll(sourceCopy)
	if err := copySessionDirectory(source, sourceCopy); err != nil {
		return nil, counts, errors.New("cannot copy source Local Storage safely")
	}
	prepared, err := os.MkdirTemp(filepath.Dir(target), ".wootc-session-backup-*")
	if err != nil {
		return nil, counts, errors.New("cannot stage target Local Storage")
	}
	r := &sessionReplacement{target: target, prepared: prepared, originalDigest: targetDigest}
	defer func() {
		if resultErr != nil {
			r.discard()
		}
	}()
	if err := copySessionDirectory(target, prepared); err != nil {
		return nil, counts, errors.New("cannot copy target Local Storage safely")
	}
	src, err := leveldb.OpenFile(sourceCopy, &opt.Options{ReadOnly: true, ErrorIfMissing: true, Strict: opt.StrictAll})
	if err != nil {
		return nil, counts, errors.New("source Local Storage is locked, corrupt, or unsupported")
	}
	defer src.Close()
	dst, err := leveldb.OpenFile(prepared, &opt.Options{ErrorIfMissing: true, Strict: opt.StrictAll})
	if err != nil {
		return nil, counts, errors.New("target Local Storage is corrupt or unsupported")
	}
	defer dst.Close()
	for _, db := range []*leveldb.DB{src, dst} {
		version, err := db.Get([]byte("VERSION"), nil)
		if err != nil || string(version) != "1" {
			return nil, counts, errors.New("unsupported Local Storage schema; no records installed")
		}
	}
	origins := make(map[string]bool)
	it := dst.NewIterator(nil, nil)
	for it.Next() {
		if origin := localStorageOrigin(it.Key()); origin != "" {
			origins[origin] = true
		}
	}
	iterErr := it.Error()
	it.Release()
	if iterErr != nil {
		return nil, counts, errors.New("cannot enumerate target Local Storage")
	}
	batch := new(leveldb.Batch)
	it = src.NewIterator(nil, nil)
	for it.Next() {
		if err := ctx.Err(); err != nil {
			it.Release()
			return nil, counts, err
		}
		key := it.Key()
		if bytes.Equal(key, []byte("VERSION")) {
			continue
		}
		if origin := localStorageOrigin(key); origin != "" && origins[origin] {
			counts.Preserved++
			continue
		}
		exists, err := dst.Has(key, nil)
		if err != nil {
			it.Release()
			return nil, counts, errors.New("cannot inspect target Local Storage key")
		}
		if exists {
			counts.Preserved++
			continue
		}
		batch.Put(key, it.Value()) // Batch copies iterator-owned slices.
		counts.Written++
	}
	iterErr = it.Error()
	it.Release()
	if iterErr != nil {
		return nil, counts, errors.New("cannot enumerate source Local Storage")
	}
	if err := dst.Write(batch, &opt.WriteOptions{Sync: true}); err != nil {
		return nil, counts, errors.New("Local Storage transaction failed")
	}
	if err := dst.Close(); err != nil {
		return nil, counts, errors.New("Local Storage did not close cleanly")
	}
	currentSource, err := sessionStoreDigest(source)
	if err != nil || sourceDigest != currentSource {
		return nil, counts, errors.New("source Local Storage changed during import")
	}
	return r, counts, nil
}

func sessionProfileName(name string) bool {
	return name == "Default" || (strings.HasPrefix(name, "Profile ") && len(name) > len("Profile ") && strings.IndexFunc(name[len("Profile "):], func(r rune) bool { return r < '0' || r > '9' }) == -1)
}
