package main

import (
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"wootc/internal/artifactauth"
)

func TestStagedManifestRequiresEmbeddedKeySignature(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(nil)
	old := artifactPublicKey
	t.Cleanup(func() { artifactPublicKey = old })
	artifactPublicKey = hex.EncodeToString(pub)
	dir := t.TempDir()
	path := filepath.Join(dir, "SHA256SUMS")
	data := []byte(strings.Repeat("a", 64) + "  deployer-vmlinuz\n")
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := fetchArtifactChecksums(context.Background(), dir); err == nil {
		t.Fatal("accepted unsigned staged manifest")
	}
	if err := os.WriteFile(path+".sig", artifactauth.Sign(key, data), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := fetchArtifactChecksums(context.Background(), dir); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(strings.Repeat("b", 64)+"  deployer-vmlinuz\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := fetchArtifactChecksums(context.Background(), dir); err == nil {
		t.Fatal("accepted edited staged manifest")
	}
}

func TestArtifactTransportRejectsDowngradeAndAmbientProxy(t *testing.T) {
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:1")
	client := newArtifactClient()
	if client.Transport.(*http.Transport).Proxy != nil {
		t.Fatal("inherits proxy")
	}
	for _, raw := range []string{"http://example.com", "file:///tmp/artifact", "https://user:pass@example.com", "https://example.com/#fragment"} {
		if err := validateArtifactURL(raw); err == nil {
			t.Fatalf("accepted %q", raw)
		}
	}
	plain := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("followed insecure redirect") }))
	defer plain.Close()
	secure := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, plain.URL, http.StatusFound) }))
	defer secure.Close()
	client.Transport = secure.Client().Transport
	if _, err := client.Get(secure.URL); err == nil {
		t.Fatal("accepted HTTPS downgrade")
	}
}

func TestDownloadedManifestAuthentication(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(nil)
	data := []byte(strings.Repeat("a", 64) + "  deployer-vmlinuz\n")
	bad := false
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, ".sig") {
			sig := artifactauth.Sign(key, data)
			if bad {
				sig[0] ^= 1
			}
			_, _ = w.Write(sig)
		} else {
			_, _ = w.Write(data)
		}
	}))
	defer server.Close()
	oldClient, oldBase, oldTag, oldKey := artifactClient, releasesBaseURL, releaseTag, artifactPublicKey
	t.Cleanup(func() {
		artifactClient, releasesBaseURL, releaseTag, artifactPublicKey = oldClient, oldBase, oldTag, oldKey
	})
	artifactClient = server.Client()
	releasesBaseURL = server.URL + "/"
	releaseTag = "v1"
	artifactPublicKey = hex.EncodeToString(pub)
	if _, err := fetchArtifactChecksums(context.Background(), t.TempDir()); err != nil {
		t.Fatal(err)
	}
	bad = true
	if _, err := fetchArtifactChecksums(context.Background(), t.TempDir()); err == nil {
		t.Fatal("accepted forged downloaded signature")
	}
}
