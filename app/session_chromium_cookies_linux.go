//go:build linux

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
	_ "modernc.org/sqlite"
)

// Chromium's schema 23/24 columns, from net/extras/sqlite/
// sqlite_persistent_cookie_store.cc. Version 24 prepends SHA256(host_key)
// before encryption. Never change the target schema or downgrade its version.
var sessionCookieColumns = []string{
	"creation_utc", "host_key", "top_frame_site_key", "name", "value", "encrypted_value",
	"path", "expires_utc", "is_secure", "is_httponly", "last_access_utc", "has_expires",
	"is_persistent", "priority", "samesite", "source_scheme", "source_port", "last_update_utc",
	"source_type", "has_cross_site_ancestor",
}

type sessionRewriteCounts struct {
	Written   int `json:"written"`
	Preserved int `json:"preserved"`
}

// A prepared replacement is adjacent to the original (same filesystem). Linux
// RENAME_EXCHANGE installs it atomically and retains the entire original as the
// backup, including for directories. A failed later store/ledger write swaps
// it back; no overwrite/merge of the user's original files occurs in place.
type sessionReplacement struct {
	target          string
	prepared        string
	originalDigest  [32]byte
	installed       bool
	installedDigest [32]byte
	installedInfo   os.FileInfo
	retainPrepared  bool
	rollbackGuard   func() error
}

func safeSessionPath(path string) error {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return errors.New("session store path must be absolute and clean")
	}
	current := string(filepath.Separator)
	for _, component := range strings.Split(strings.TrimPrefix(path, current), string(filepath.Separator)) {
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if err != nil || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("session store path is missing or traverses a symbolic link")
		}
	}
	return nil
}

func sessionFileDigest(path string) ([32]byte, error) {
	var digest [32]byte
	f, err := os.OpenFile(path, os.O_RDONLY|unix.O_NOFOLLOW, 0)
	if err != nil {
		return digest, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return digest, err
	}
	copy(digest[:], h.Sum(nil))
	return digest, nil
}

func (r *sessionReplacement) install() error {
	if err := safeSessionPath(r.target); err != nil {
		return err
	}
	digest, err := sessionStoreDigest(r.target)
	if err != nil || digest != r.originalDigest {
		return errors.New("target session store changed during import")
	}
	stagedInfo, err := os.Lstat(r.prepared)
	if err != nil {
		return errors.New("cannot inspect staged session store")
	}
	stagedDigest, err := sessionStoreDigest(r.prepared)
	if err != nil {
		return errors.New("cannot fingerprint staged session store")
	}
	if err := unix.Renameat2(unix.AT_FDCWD, r.prepared, unix.AT_FDCWD, r.target, unix.RENAME_EXCHANGE); err != nil {
		return errors.New("filesystem cannot atomically exchange the session store; original is unchanged")
	}
	r.installed = true
	r.installedInfo = stagedInfo
	r.installedDigest = stagedDigest
	return syncSessionDirectory(filepath.Dir(r.target))
}

func (r *sessionReplacement) rollback() error {
	if !r.installed {
		return nil
	}
	// Other importers are excluded, but Chrome is not. Refuse to replace
	// browser-written state, even when the cause of rollback is a new browser
	// process. Both current state and original backup remain recoverable.
	refuse := func() error {
		return fmt.Errorf("session rollback refused because the published store is active or changed; current state retained at %s; original backup retained at %s", r.target, r.prepared)
	}
	if r.rollbackGuard != nil {
		if err := r.rollbackGuard(); err != nil {
			return refuse()
		}
	}
	if err := safeSessionPath(r.target); err != nil {
		return refuse()
	}
	info, err := os.Lstat(r.target)
	if err != nil || r.installedInfo == nil || !os.SameFile(info, r.installedInfo) {
		return refuse()
	}
	if info.Mode().IsRegular() {
		for _, suffix := range []string{"-wal", "-shm", "-journal"} {
			if _, err := os.Lstat(r.target + suffix); !os.IsNotExist(err) {
				return refuse()
			}
		}
	}
	digest, err := sessionStoreDigest(r.target)
	if err != nil || digest != r.installedDigest {
		return refuse()
	}
	backupDigest, err := sessionStoreDigest(r.prepared)
	if err != nil || backupDigest != r.originalDigest {
		return refuse()
	}
	if err := unix.Renameat2(unix.AT_FDCWD, r.prepared, unix.AT_FDCWD, r.target, unix.RENAME_EXCHANGE); err != nil {
		return fmt.Errorf("session rollback failed; original retained at %s", r.prepared)
	}
	r.installed = false
	// A browser can resume between the fingerprint and exchange. Never
	// delete a store that has been published, including after a clean
	// rollback: an existing native file descriptor may still write to it.
	r.retainPrepared = true
	return syncSessionDirectory(filepath.Dir(r.target))
}

func (r *sessionReplacement) discard() {
	if !r.installed && !r.retainPrepared {
		_ = os.RemoveAll(r.prepared)
	}
}

func syncSessionDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return errors.New("cannot open session store directory for durable publication")
	}
	defer directory.Close()
	if err := directory.Sync(); err != nil {
		return errors.New("cannot durably publish session store directory")
	}
	return nil
}

func requireClosedSQLite(path string) error {
	if err := safeSessionPath(path); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return errors.New("cookie store must be a regular file")
	}
	for _, suffix := range []string{"-wal", "-journal"} {
		info, err := os.Lstat(path + suffix)
		if err == nil && (info.Mode()&os.ModeSymlink != 0 || info.Size() != 0) {
			return errors.New("cookie store has an active WAL/journal; close the browser cleanly first")
		}
		if err != nil && !os.IsNotExist(err) {
			return errors.New("cannot inspect cookie store journal")
		}
	}
	return nil
}

func openSessionSQLite(path string, readonly bool) (*sql.DB, error) {
	u := url.URL{Scheme: "file", Path: path}
	q := u.Query()
	if readonly {
		q.Set("mode", "ro")
		q.Set("immutable", "1") // inputs are closed, journal-free stores
	}
	q.Add("_pragma", "trusted_schema(OFF)")
	u.RawQuery = q.Encode()
	db, err := sql.Open("sqlite", u.String())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	return db, nil
}

func sessionCookieVersion(ctx context.Context, db *sql.DB) (int, error) {
	var version, compatible int
	if err := db.QueryRowContext(ctx, `SELECT value FROM meta WHERE key='version'`).Scan(&version); err != nil {
		return 0, errors.New("cookie database has no supported version metadata")
	}
	if err := db.QueryRowContext(ctx, `SELECT value FROM meta WHERE key='last_compatible_version'`).Scan(&compatible); err != nil {
		return 0, errors.New("cookie database has no compatibility metadata")
	}
	if (version != 23 && version != 24) || compatible > version || compatible < 1 {
		return 0, errors.New("unsupported cookie database version; sign in once instead")
	}
	rows, err := db.QueryContext(ctx, `PRAGMA table_info(cookies)`)
	if err != nil {
		return 0, errors.New("cannot inspect cookie schema")
	}
	defer rows.Close()
	var columns []string
	for rows.Next() {
		var cid, notnull, primary int
		var name, kind string
		var defaultValue any
		if err := rows.Scan(&cid, &name, &kind, &notnull, &defaultValue, &primary); err != nil {
			return 0, errors.New("cannot read cookie schema")
		}
		columns = append(columns, name)
	}
	if err := rows.Err(); err != nil || strings.Join(columns, ",") != strings.Join(sessionCookieColumns, ",") {
		return 0, errors.New("unsupported cookie table layout")
	}
	return version, nil
}

// prepareChromiumCookies merges missing source cookies into an already
// initialized Linux store. Existing cookie identities win. All source rows are
// validated before install; v20 app-bound/unknown formats and bad tags abort the
// entire merge. The source is read-only; plaintext exists only in memory.
func prepareChromiumCookies(ctx context.Context, source, target string, windowsKey []byte, encryptor sessionValueEncryptor) (_ *sessionReplacement, counts sessionRewriteCounts, resultErr error) {
	if encryptor == nil || len(windowsKey) != 32 {
		return nil, counts, errors.New("cookie import needs an unlocked envelope and target keyring")
	}
	for _, path := range []string{source, target} {
		if err := requireClosedSQLite(path); err != nil {
			return nil, counts, err
		}
	}
	sourceDigest, err := sessionFileDigest(source)
	if err != nil {
		return nil, counts, errors.New("cannot snapshot source cookie store")
	}
	src, err := openSessionSQLite(source, true)
	if err != nil {
		return nil, counts, errors.New("cannot open source cookie store")
	}
	defer src.Close()
	sourceVersion, err := sessionCookieVersion(ctx, src)
	if err != nil {
		return nil, counts, err
	}
	targetDigest, err := sessionFileDigest(target)
	if err != nil {
		return nil, counts, errors.New("cannot snapshot target cookie store")
	}
	// Reject existing plaintext rows before copying: no temporary file created
	// by this importer should acquire unencrypted tokens from either profile.
	original, err := openSessionSQLite(target, true)
	if err != nil {
		return nil, counts, errors.New("cannot open target cookie store")
	}
	targetVersion, versionErr := sessionCookieVersion(ctx, original)
	var plaintextRows int
	plainErr := original.QueryRowContext(ctx, `SELECT count(*) FROM cookies WHERE length(value)>0`).Scan(&plaintextRows)
	original.Close()
	if versionErr != nil {
		return nil, counts, versionErr
	}
	if plainErr != nil || plaintextRows != 0 {
		return nil, counts, errors.New("target contains plaintext cookies; refusing to copy credentials into temporary files")
	}
	f, err := os.CreateTemp(filepath.Dir(target), ".wootc-session-backup-*")
	if err != nil {
		return nil, counts, errors.New("cannot create private cookie staging file")
	}
	r := &sessionReplacement{target: target, prepared: f.Name(), originalDigest: targetDigest}
	defer func() {
		if resultErr != nil {
			r.discard()
		}
	}()
	input, err := os.Open(target)
	if err != nil {
		f.Close()
		return nil, counts, errors.New("cannot copy target cookie store")
	}
	_, copyErr := io.Copy(f, input)
	input.Close()
	syncErr := f.Sync()
	closeErr := f.Close()
	if copyErr != nil || syncErr != nil || closeErr != nil {
		return nil, counts, errors.New("cannot stage target cookie store")
	}
	dst, err := openSessionSQLite(r.prepared, false)
	if err != nil {
		return nil, counts, errors.New("cannot open staged cookie store")
	}
	defer dst.Close()
	// No WAL: all persistent writes are ciphertext only and all sidecars are
	// removed by SQLite on close. Journaling contains only preexisting ciphertext.
	if _, err := dst.ExecContext(ctx, `PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON`); err != nil {
		return nil, counts, errors.New("cannot configure staged cookie transaction")
	}
	tx, err := dst.BeginTx(ctx, nil)
	if err != nil {
		return nil, counts, errors.New("cannot start cookie transaction")
	}
	defer tx.Rollback()
	rows, err := src.QueryContext(ctx, `SELECT `+strings.Join(sessionCookieColumns, ",")+` FROM cookies ORDER BY rowid`)
	if err != nil {
		return nil, counts, errors.New("cannot enumerate source cookies")
	}
	defer rows.Close()
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(sessionCookieColumns)), ",")
	insert, err := tx.PrepareContext(ctx, `INSERT INTO cookies (`+strings.Join(sessionCookieColumns, ",")+`) VALUES (`+placeholders+`) ON CONFLICT(host_key,top_frame_site_key,has_cross_site_ancestor,name,path,source_scheme,source_port) DO NOTHING`)
	if err != nil {
		return nil, counts, errors.New("target cookie schema is incompatible")
	}
	defer insert.Close()
	for rows.Next() {
		values := make([]any, len(sessionCookieColumns))
		pointers := make([]any, len(values))
		for i := range values {
			pointers[i] = &values[i]
		}
		if err := rows.Scan(pointers...); err != nil {
			return nil, counts, errors.New("cannot decode cookie row")
		}
		host, hostOK := values[1].(string)
		plain, plainOK := values[4].(string)
		var encrypted []byte
		switch value := values[5].(type) {
		case []byte:
			encrypted = value
		case string:
			encrypted = []byte(value)
		default:
			return nil, counts, errors.New("cookie encrypted_value is not a blob")
		}
		if !hostOK || !plainOK || (plain != "" && len(encrypted) != 0) {
			return nil, counts, errors.New("cookie row has ambiguous or unsupported value fields")
		}
		var payload []byte
		if len(encrypted) != 0 {
			payload, err = decryptChromiumValue(windowsKey, encrypted)
			if err != nil {
				return nil, counts, errors.New("source cookie has unsupported encryption or failed authentication; no cookies installed")
			}
			if sourceVersion == 24 {
				domainHash := sha256.Sum256([]byte(host))
				if len(payload) < len(domainHash) || !bytes.Equal(payload[:len(domainHash)], domainHash[:]) {
					clear(payload)
					return nil, counts, errors.New("source cookie domain binding failed; no cookies installed")
				}
				copy(payload, payload[len(domainHash):])
				clear(payload[len(payload)-len(domainHash):])
				payload = payload[:len(payload)-len(domainHash)]
			}
		} else {
			payload = []byte(plain)
		}
		if targetVersion == 24 {
			domainHash := sha256.Sum256([]byte(host))
			bound := make([]byte, len(domainHash)+len(payload))
			copy(bound, domainHash[:])
			copy(bound[len(domainHash):], payload)
			clear(payload)
			payload = bound
		}
		sealed, sealErr := encryptor.Encrypt(payload)
		clear(payload)
		if sealErr != nil {
			return nil, counts, errors.New("target keyring encryption failed; no cookies installed")
		}
		values[4], values[5] = "", sealed
		result, err := insert.ExecContext(ctx, values...)
		if err != nil {
			return nil, counts, errors.New("cannot merge cookie row; no cookies installed")
		}
		n, err := result.RowsAffected()
		if err != nil {
			return nil, counts, errors.New("cannot determine cookie merge result")
		}
		if n == 1 {
			counts.Written++
		} else {
			counts.Preserved++
		}
	}
	if err := rows.Err(); err != nil {
		return nil, counts, errors.New("source cookie enumeration failed")
	}
	currentSourceDigest, err := sessionFileDigest(source)
	if err != nil || currentSourceDigest != sourceDigest {
		return nil, counts, errors.New("source cookie store changed during import")
	}
	if err := tx.Commit(); err != nil {
		return nil, counts, errors.New("cookie transaction could not commit")
	}
	if err := dst.Close(); err != nil {
		return nil, counts, errors.New("cookie store did not close cleanly")
	}
	return r, counts, nil
}
