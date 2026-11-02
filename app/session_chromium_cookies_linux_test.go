//go:build linux

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type sessionCookieFixture struct {
	host, name, plaintext string
	encrypted             []byte
}

// Synthetic rows in Chromium's upstream V23/V24 schema, not captured account
// sessions. These tests prove SQLite/wire/rollback behavior, never service auth.
func writeSessionCookieFixture(t *testing.T, path string, version int, cookies ...sessionCookieFixture) {
	t.Helper()
	db, err := openSessionSQLite(path, false)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	_, err = db.Exec(`CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
CREATE TABLE cookies(creation_utc INTEGER NOT NULL,host_key TEXT NOT NULL,top_frame_site_key TEXT NOT NULL,name TEXT NOT NULL,value TEXT NOT NULL,encrypted_value BLOB NOT NULL,path TEXT NOT NULL,expires_utc INTEGER NOT NULL,is_secure INTEGER NOT NULL,is_httponly INTEGER NOT NULL,last_access_utc INTEGER NOT NULL,has_expires INTEGER NOT NULL,is_persistent INTEGER NOT NULL,priority INTEGER NOT NULL,samesite INTEGER NOT NULL,source_scheme INTEGER NOT NULL,source_port INTEGER NOT NULL,last_update_utc INTEGER NOT NULL,source_type INTEGER NOT NULL,has_cross_site_ancestor INTEGER NOT NULL);
CREATE UNIQUE INDEX cookies_unique_index ON cookies(host_key,top_frame_site_key,has_cross_site_ancestor,name,path,source_scheme,source_port);`)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"version", "last_compatible_version"} {
		if _, err := db.Exec(`INSERT INTO meta VALUES(?,?)`, key, version); err != nil {
			t.Fatal(err)
		}
	}
	for _, cookie := range cookies {
		encrypted := cookie.encrypted
		if encrypted == nil {
			encrypted = []byte{}
		}
		_, err := db.Exec(`INSERT INTO cookies VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
			int64(1), cookie.host, "", cookie.name, cookie.plaintext, encrypted, "/", int64(100), 1, 1, int64(2), 1, 1, 1, -1, 2, 443, int64(3), 1, 0)
		if err != nil {
			t.Fatal(err)
		}
	}
}

func sessionCookieBlob(t *testing.T, path, name string) []byte {
	t.Helper()
	db, err := openSessionSQLite(path, true)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var encrypted []byte
	var plain string
	if err := db.QueryRow(`SELECT value,encrypted_value FROM cookies WHERE name=?`, name).Scan(&plain, &encrypted); err != nil {
		t.Fatal(err)
	}
	if plain != "" {
		t.Fatal("plaintext cookie remained in output")
	}
	return encrypted
}

func TestChromiumCookiesTransactionalMergeAndIdempotence(t *testing.T) {
	for _, versions := range [][2]int{{23, 23}, {23, 24}, {24, 23}, {24, 24}} {
		t.Run(fmt.Sprintf("%d-to-%d", versions[0], versions[1]), func(t *testing.T) {
			dir := t.TempDir()
			source, target := filepath.Join(dir, "WindowsCookies"), filepath.Join(dir, "LinuxCookies")
			key := bytes.Repeat([]byte{0x7b}, 32)
			payload := []byte("disposable-cookie-fixture")
			if versions[0] == 24 {
				hash := sha256.Sum256([]byte(".example.com"))
				payload = append(hash[:], payload...)
			}
			writeSessionCookieFixture(t, source, versions[0], sessionCookieFixture{host: ".example.com", name: "new", encrypted: sealChromiumValue(t, key, payload)})
			encryptor, err := newLinuxSafeStorageEncryptor(context.Background(), []byte(safeStorageFixturePassword))
			if err != nil {
				t.Fatal(err)
			}
			defer encryptor.(io.Closer).Close()
			existing, err := encryptor.Encrypt([]byte("existing-linux-cookie"))
			if err != nil {
				t.Fatal(err)
			}
			writeSessionCookieFixture(t, target, versions[1], sessionCookieFixture{host: ".existing.example", name: "existing", encrypted: existing})
			original, _ := os.ReadFile(target)
			sourceBefore, _ := os.ReadFile(source)
			replacement, counts, err := prepareChromiumCookies(context.Background(), source, target, key, encryptor)
			if err != nil {
				t.Fatal(err)
			}
			defer replacement.discard()
			if counts.Written != 1 {
				t.Fatalf("written=%d, want1", counts.Written)
			}
			unchanged, _ := os.ReadFile(target)
			if !bytes.Equal(original, unchanged) {
				t.Fatal("prepare modified live target")
			}
			expectedPayload := []byte("disposable-cookie-fixture")
			if versions[1] == 24 {
				hash := sha256.Sum256([]byte(".example.com"))
				expectedPayload = append(hash[:], expectedPayload...)
			}
			expected, err := encryptor.Encrypt(expectedPayload)
			if err != nil {
				t.Fatal(err)
			}
			if got := sessionCookieBlob(t, replacement.prepared, "new"); !bytes.Equal(got, expected) {
				t.Fatal("domain binding/cipher conversion differs")
			}
			if err := replacement.install(); err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(sessionCookieBlob(t, target, "existing"), existing) {
				t.Fatal("existing cookie replaced")
			}
			backup, _ := os.ReadFile(replacement.prepared)
			if !bytes.Equal(backup, original) {
				t.Fatal("backup does not preserve original target bytes")
			}
			second, counts, err := prepareChromiumCookies(context.Background(), source, target, key, encryptor)
			if err != nil {
				t.Fatal(err)
			}
			defer second.discard()
			if counts.Written != 0 || counts.Preserved != 1 {
				t.Fatal("repeat import overwrote target cookie identity")
			}
			if err := replacement.rollback(); err != nil {
				t.Fatal(err)
			}
			restored, _ := os.ReadFile(target)
			if !bytes.Equal(restored, original) {
				t.Fatal("rollback did not restore exact original")
			}
			afterSource, _ := os.ReadFile(source)
			if !bytes.Equal(afterSource, sourceBefore) {
				t.Fatal("source store changed")
			}
			entries, _ := os.ReadDir(dir)
			for _, entry := range entries {
				if entry.IsDir() {
					continue
				}
				data, _ := os.ReadFile(filepath.Join(dir, entry.Name()))
				if bytes.Contains(data, []byte("disposable-cookie-fixture")) {
					t.Fatal("plaintext token found in database/temporary file")
				}
			}
		})
	}
}

func TestChromiumCookiesUnsupportedOrTamperedRowsRollbackAll(t *testing.T) {
	for _, mode := range []string{"v20", "tampered", "wrong-domain", "unsupported-schema", "active-wal"} {
		t.Run(mode, func(t *testing.T) {
			dir := t.TempDir()
			source, target := filepath.Join(dir, "WindowsCookies"), filepath.Join(dir, "LinuxCookies")
			key := bytes.Repeat([]byte{0x5c}, 32)
			valid := sealChromiumValue(t, key, []byte("one"))
			bad := sealChromiumValue(t, key, []byte("two"))
			version := 23
			switch mode {
			case "v20":
				copy(bad[:3], []byte("v20"))
			case "tampered":
				bad[len(bad)-1] ^= 1
			case "wrong-domain":
				version = 24
				bad = sealChromiumValue(t, key, bytes.Repeat([]byte{0}, 40))
				valid = bad
			case "unsupported-schema":
				version = 25
			}
			writeSessionCookieFixture(t, source, version, sessionCookieFixture{host: ".example.com", name: "valid", encrypted: valid}, sessionCookieFixture{host: ".example.com", name: "bad", encrypted: bad})
			writeSessionCookieFixture(t, target, 24)
			before, _ := os.ReadFile(target)
			if mode == "active-wal" {
				if err := os.WriteFile(source+"-wal", []byte("active"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			encryptor, err := newLinuxSafeStorageEncryptor(context.Background(), []byte(safeStorageFixturePassword))
			if err != nil {
				t.Fatal(err)
			}
			defer encryptor.(io.Closer).Close()
			if replacement, _, err := prepareChromiumCookies(context.Background(), source, target, key, encryptor); err == nil {
				replacement.discard()
				t.Fatal("unsupported/damaged source installed")
			}
			after, _ := os.ReadFile(target)
			if !bytes.Equal(before, after) {
				t.Fatal("failed rewrite damaged target")
			}
			entries, _ := os.ReadDir(dir)
			for _, entry := range entries {
				if strings.HasPrefix(entry.Name(), ".wootc-session-") {
					t.Fatal("failed import retained staging material")
				}
			}
		})
	}
}

func TestChromiumCookiesChangedDestinationAndPlaintextTargetFailClosed(t *testing.T) {
	dir := t.TempDir()
	source, target := filepath.Join(dir, "source"), filepath.Join(dir, "target")
	key := bytes.Repeat([]byte{2}, 32)
	writeSessionCookieFixture(t, source, 23, sessionCookieFixture{host: "example.com", name: "new", plaintext: "source-plain-cookie"})
	writeSessionCookieFixture(t, target, 23)
	encryptor, err := newLinuxSafeStorageEncryptor(context.Background(), []byte(safeStorageFixturePassword))
	if err != nil {
		t.Fatal(err)
	}
	defer encryptor.(io.Closer).Close()
	replacement, _, err := prepareChromiumCookies(context.Background(), source, target, key, encryptor)
	if err != nil {
		t.Fatal(err)
	}
	defer replacement.discard()
	db, err := sql.Open("sqlite", target)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO meta VALUES('user-change','preserve')`); err != nil {
		t.Fatal(err)
	}
	db.Close()
	changed, _ := os.ReadFile(target)
	if err := replacement.install(); err == nil {
		t.Fatal("changed target replaced")
	}
	after, _ := os.ReadFile(target)
	if !bytes.Equal(changed, after) {
		t.Fatal("concurrent target edit lost")
	}
	plainTarget := filepath.Join(dir, "plaintext-target")
	writeSessionCookieFixture(t, plainTarget, 23, sessionCookieFixture{host: "example.com", name: "plain", plaintext: "private"})
	if replacement, _, err := prepareChromiumCookies(context.Background(), source, plainTarget, key, encryptor); err == nil {
		replacement.discard()
		t.Fatal("plaintext target copied to temporary file")
	}
}
