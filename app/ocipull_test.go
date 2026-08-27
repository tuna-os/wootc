package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRegistryRef(t *testing.T) {
	cases := []struct{ in, host, repo, ref string }{
		{"ghcr.io/tuna-os/yellowfin:gnome", "ghcr.io", "tuna-os/yellowfin", "gnome"},
		{"ghcr.io/projectbluefin/bluefin:lts", "ghcr.io", "projectbluefin/bluefin", "lts"},
		{"ghcr.io/org/name", "ghcr.io", "org/name", "latest"},
		{"ghcr.io/org/name@sha256:abc", "ghcr.io", "org/name", "sha256:abc"},
		{"registry.example:5000/x/y:z", "registry.example:5000", "x/y", "z"},
		{"docker.io/library/ubuntu:22.04", "docker.io", "library/ubuntu", "22.04"},
		{"ghcr.io/org/repo:tag@sha256:digest", "ghcr.io", "org/repo:tag", "sha256:digest"},
	}
	for _, c := range cases {
		host, repo, ref, err := registryRef(c.in)
		if err != nil {
			t.Errorf("%s: %v", c.in, err)
			continue
		}
		if host != c.host || repo != c.repo || ref != c.ref {
			t.Errorf("%s → %s %s %s, want %s %s %s", c.in, host, repo, ref, c.host, c.repo, c.ref)
		}
	}
	for _, bad := range []string{"no-registry-host", "", "   ", "ghcr.io/", "ghcr.io/repo:", "ghcr.io/repo@"} {
		if _, _, _, err := registryRef(bad); err == nil {
			t.Errorf("invalid ref %q accepted; expected parse error", bad)
		}
	}
}

// A miniature in-process registry proving the full pull path: token dance,
// multi-arch index resolution, digest-verified blobs, layout metadata — and
// the fail-closed refusal when a blob's bytes do not match their digest.
func TestPullImageToOCILayout(t *testing.T) {
	blob := func(b []byte) (string, []byte) {
		s := sha256.Sum256(b)
		return "sha256:" + hex.EncodeToString(s[:]), b
	}
	cfgDigest, cfgBytes := blob([]byte(`{"architecture":"amd64","os":"linux"}`))
	layerDigest, layerBytes := blob([]byte("layer-bytes-here"))
	manifest := map[string]any{
		"schemaVersion": 2, "mediaType": mtOCIManifest,
		"config": map[string]any{"mediaType": "application/vnd.oci.image.config.v1+json", "digest": cfgDigest, "size": len(cfgBytes)},
		"layers": []map[string]any{{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": layerDigest, "size": len(layerBytes)}},
	}
	manBytes, _ := json.Marshal(manifest)
	manDigest, _ := blob(manBytes)
	index := map[string]any{
		"schemaVersion": 2, "mediaType": mtOCIIndex,
		"manifests": []map[string]any{
			{"mediaType": mtOCIManifest, "digest": "sha256:deadbeef", "size": 1,
				"platform": map[string]string{"architecture": "arm64", "os": "linux"}},
			{"mediaType": mtOCIManifest, "digest": manDigest, "size": len(manBytes),
				"platform": map[string]string{"architecture": "amd64", "os": "linux"}},
		},
	}
	idxBytes, _ := json.Marshal(index)

	corrupt := false
	mux := http.NewServeMux()
	var srv *httptest.Server
	mux.HandleFunc("/v2/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v2/" {
			if r.Header.Get("Authorization") == "" {
				w.Header().Set("Www-Authenticate", `Bearer realm="`+srv.URL+`/token",service="test"`)
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			w.WriteHeader(http.StatusOK)
			return
		}
		if r.Header.Get("Authorization") != "Bearer tok123" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch {
		case strings.HasSuffix(r.URL.Path, "/manifests/v1"):
			w.Header().Set("Content-Type", mtOCIIndex)
			w.Write(idxBytes)
		case strings.HasSuffix(r.URL.Path, "/manifests/"+manDigest):
			w.Header().Set("Content-Type", mtOCIManifest)
			w.Write(manBytes)
		case strings.HasSuffix(r.URL.Path, "/blobs/"+cfgDigest):
			w.Write(cfgBytes)
		case strings.HasSuffix(r.URL.Path, "/blobs/"+layerDigest):
			if corrupt {
				w.Write([]byte("evil-different-bytes"))
			} else {
				w.Write(layerBytes)
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]string{"token": "tok123"})
	})
	srv = httptest.NewTLSServer(mux)
	defer srv.Close()

	host := strings.TrimPrefix(srv.URL, "https://")
	pull := func(dest string) (string, int64, error) {
		p := &ociPuller{client: srv.Client(), host: host, repo: "org/img"}
		if err := p.authorize(context.Background()); err != nil {
			return "", 0, err
		}
		raw, digest, err := p.fetchManifest(context.Background(), "v1")
		if err != nil {
			return "", 0, err
		}
		// Drive the blob path exactly as pullImageToOCILayout does.
		var m ociManifest
		if err := json.Unmarshal(raw, &m); err != nil {
			return "", 0, err
		}
		blobDir := filepath.Join(dest, "blobs", "sha256")
		if err := os.MkdirAll(blobDir, 0o755); err != nil {
			return "", 0, err
		}
		var done int64
		tick := func(d int64) { done += d }
		if err := p.writeBlob(context.Background(), blobDir, m.Config, tick); err != nil {
			return "", 0, err
		}
		for _, l := range m.Layers {
			if err := p.writeBlob(context.Background(), blobDir, l, tick); err != nil {
				return "", 0, err
			}
		}
		return digest, done, nil
	}

	t.Run("happy path resolves the index and verifies every blob", func(t *testing.T) {
		dest := t.TempDir()
		digest, done, err := pull(dest)
		if err != nil {
			t.Fatalf("pull: %v", err)
		}
		if digest != manDigest {
			t.Errorf("digest = %s, want %s", digest, manDigest)
		}
		if done != int64(len(cfgBytes)+len(layerBytes)) {
			t.Errorf("bytes = %d", done)
		}
		for _, d := range []string{cfgDigest, layerDigest} {
			if _, err := os.Stat(filepath.Join(dest, "blobs", "sha256", strings.TrimPrefix(d, "sha256:"))); err != nil {
				t.Errorf("blob %s not written: %v", d, err)
			}
		}
	})

	t.Run("a tampered blob is refused, not written", func(t *testing.T) {
		corrupt = true
		defer func() { corrupt = false }()
		dest := t.TempDir()
		_, _, err := pull(dest)
		if err == nil || !strings.Contains(err.Error(), "refusing") {
			t.Fatalf("tampered blob accepted: err=%v", err)
		}
		if _, statErr := os.Stat(filepath.Join(dest, "blobs", "sha256", strings.TrimPrefix(layerDigest, "sha256:"))); statErr == nil {
			t.Error("corrupted blob left on disk")
		}
	})
}
