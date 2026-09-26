//go:build windows

package main

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"wootc/internal/artifactauth"
)

func TestSignedDeployerPipeline(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(nil)
	var manifest strings.Builder
	artifacts := map[string][]byte{}
	for _, name := range []string{"deployer-vmlinuz", "deployer-initramfs.img", "shimx64.efi", "grubx64.efi", "mmx64.efi", "wubildr.efi"} {
		body := []byte("fixture bytes for " + name)
		artifacts[name] = body
		fmt.Fprintf(&manifest, "%x  %s\n", sha256.Sum256(body), name)
	}
	data := []byte(manifest.String())
	downloads := 0
	corrupt := false
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, ok := artifacts[filepath.Base(r.URL.Path)]
		if !ok {
			t.Errorf("unexpected request: %s", r.URL.Path)
			http.NotFound(w, r)
			return
		}
		downloads++
		if corrupt {
			body = []byte("corrupted download")
		}
		_, _ = w.Write(body)
	}))
	defer server.Close()
	oldClient, oldBase, oldKey := artifactClient, releasesBaseURL, artifactPublicKey
	t.Cleanup(func() { artifactClient, releasesBaseURL, artifactPublicKey = oldClient, oldBase, oldKey })
	artifactClient, releasesBaseURL, artifactPublicKey = server.Client(), server.URL+"/", hex.EncodeToString(pub)
	dir := t.TempDir()
	stage := func(name string, body []byte) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), body, 0600); err != nil {
			t.Fatal(err)
		}
	}
	stage("SHA256SUMS", data)
	stage("SHA256SUMS.sig", artifactauth.Sign(key, data))
	for name, body := range artifacts {
		stage(name, body)
	}
	if err := downloadDeployerTo(context.Background(), dir, func(float64) {}); err != nil {
		t.Fatal(err)
	}
	if downloads != 0 {
		t.Fatal("signed offline cache attempted network")
	}
	stage("deployer-vmlinuz", []byte("bad cache"))
	if err := downloadDeployerTo(context.Background(), dir, func(float64) {}); err != nil {
		t.Fatal(err)
	}
	if downloads != 1 {
		t.Fatalf("cache repair downloads=%d", downloads)
	}
	corrupt = true
	stage("deployer-vmlinuz", []byte("bad cache"))
	if err := downloadDeployerTo(context.Background(), dir, func(float64) {}); err == nil {
		t.Fatal("accepted corrupted artifact")
	}
	if _, err := os.Stat(filepath.Join(dir, "deployer-vmlinuz")); !os.IsNotExist(err) {
		t.Fatalf("left rejected boot artifact: %v", err)
	}
	sig := artifactauth.Sign(key, data)
	sig[0] ^= 1
	stage("SHA256SUMS.sig", sig)
	before := downloads
	if err := downloadDeployerTo(context.Background(), dir, func(float64) {}); err == nil {
		t.Fatal("accepted forged manifest")
	}
	if downloads != before {
		t.Fatal("downloaded boot files before authentication")
	}
}
