//go:build linux

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func makeSessionEnvelopeFixture(t *testing.T, ledger string) (string, []byte, []byte) {
	t.Helper()
	dir := t.TempDir()
	secret := []byte("disposable-vault-fixture")
	key := bytes.Repeat([]byte{0x3a}, 32)
	if err := os.WriteFile(filepath.Join(dir, "exports.json"), []byte(ledger), 0o600); err != nil {
		t.Fatal(err)
	}
	blob, err := sealSessionPayload(secret, "chrome", key)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "chrome.enc"), blob, 0o600); err != nil {
		t.Fatal(err)
	}
	return dir, secret, key
}

func TestSessionEnvelopeConsumerUnlockAndNoPlaintextOutput(t *testing.T) {
	dir, secret, key := makeSessionEnvelopeFixture(t, `[{"app":"chrome","state":"staged"},{"app":"spotify","state":"imported"},{"app":"discord","state":"staged"}]`)
	before, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	store, err := openSessionEnvelopeStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.root.Close()
	if len(store.staged) != 1 {
		t.Fatal("non-staged or excluded app was eligible")
	}
	got, err := store.unlock("chrome", true, secret)
	if err != nil {
		t.Fatal(err)
	}
	defer clear(got)
	if !bytes.Equal(got, key) {
		t.Fatal("consumer returned a different key")
	}
	after, err := os.ReadDir(dir)
	if err != nil || len(before) != len(after) {
		t.Fatal("unlock created output files")
	}
	for _, entry := range after {
		data, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(data, key) || bytes.Contains(data, secret) {
			t.Fatal("plaintext key or password found on disk")
		}
	}
}

func TestSessionEnvelopeConsumerFailsClosed(t *testing.T) {
	dir, secret, _ := makeSessionEnvelopeFixture(t, `[{"app":"chrome","state":"staged"},{"app":"edge","state":"staged"}]`)
	store, err := openSessionEnvelopeStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.root.Close()
	for _, tc := range []struct {
		app     string
		consent bool
		secret  []byte
	}{
		{"../chrome", true, secret}, {"discord", true, secret}, {"chrome", false, secret},
		{"chrome", true, nil}, {"chrome", true, []byte("wrong")}, {"edge", true, secret},
	} {
		if key, err := store.unlock(tc.app, tc.consent, tc.secret); err == nil || key != nil {
			t.Fatalf("unsafe unlock accepted for %q", tc.app)
		}
	}
	blob, err := os.ReadFile(filepath.Join(dir, "chrome.enc"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "edge.enc"), blob, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.unlock("edge", true, secret); err == nil {
		t.Fatal("relabeled envelope accepted")
	}
	blob[len(blob)-1] ^= 1
	if err := os.WriteFile(filepath.Join(dir, "chrome.enc"), blob, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.unlock("chrome", true, secret); err == nil {
		t.Fatal("tampered envelope accepted")
	}
	blob[0] = 99
	if err := os.WriteFile(filepath.Join(dir, "chrome.enc"), blob, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.unlock("chrome", true, secret); err == nil {
		t.Fatal("unsupported version accepted")
	}
}

func TestSessionEnvelopeConsumerRejectsDuplicateSymlinkAndPayloadShape(t *testing.T) {
	dir, secret, _ := makeSessionEnvelopeFixture(t, `[{"app":"chrome","state":"staged"},{"app":"chrome","state":"staged"}]`)
	if store, err := openSessionEnvelopeStore(dir); err == nil {
		store.root.Close()
		t.Fatal("duplicate ledger accepted")
	}
	if err := os.WriteFile(filepath.Join(dir, "exports.json"), []byte(`[{"app":"chrome","state":"staged"}]`), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := openSessionEnvelopeStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.root.Close()
	if err := os.Rename(filepath.Join(dir, "chrome.enc"), filepath.Join(dir, "hidden.enc")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("hidden.enc", filepath.Join(dir, "chrome.enc")); err != nil {
		t.Fatal(err)
	}
	if _, err := store.unlock("chrome", true, secret); err == nil {
		t.Fatal("symlink envelope accepted")
	}
	if err := os.Remove(filepath.Join(dir, "chrome.enc")); err != nil {
		t.Fatal(err)
	}
	blob, err := sealSessionPayload(secret, "chrome", []byte("not a Windows key"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "chrome.enc"), blob, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.unlock("chrome", true, secret); err == nil {
		t.Fatal("unsupported payload accepted")
	}
}

func TestSessionImportLedgerDoesNotPromoteRewrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session-imports.json")
	if err := recordSessionImport(path, SessionImportResult{App: "chrome", State: "rewritten", Reason: "Format rewrite only"}); err != nil {
		t.Fatal(err)
	}
	outcome := readSessionImports(path)["chrome"]
	if outcome.State != "rewritten" || outcome.Verified {
		t.Fatal("rewrite promoted to verified import")
	}
	if err := recordSessionImport(path, SessionImportResult{App: "chrome", State: "failed", Reason: "Rollback"}); err != nil {
		t.Fatal(err)
	}
	outcome = readSessionImports(path)["chrome"]
	if outcome.State != "failed" || outcome.Verified {
		t.Fatal("failed rewrite retained successful state")
	}
}
