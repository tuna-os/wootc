package main

// Tests for the cross-platform helpers (helpers.go): JSON round-trips, file
// copying, and the HTTP download helper (including the #53 guard that rejects
// non-2xx responses before they can become boot artifacts).

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMarshalJSONRoundTrip(t *testing.T) {
	type sample struct {
		Name string `json:"name"`
		Size int64  `json:"size"`
	}
	in := sample{Name: "documents", Size: 42}
	data, err := marshalJSON(in)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"name": "documents"`) {
		t.Errorf("marshalJSON output missing field: %s", data)
	}
	var out sample
	if err := unmarshalJSON(data, &out); err != nil {
		t.Fatal(err)
	}
	if out != in {
		t.Errorf("round trip = %+v, want %+v", out, in)
	}
}

func TestUnmarshalJSONRejectsBadData(t *testing.T) {
	var v map[string]int
	if err := unmarshalJSON([]byte("{nope"), &v); err == nil {
		t.Error("unmarshalJSON on corrupt data returned nil error")
	}
}

func TestMarshalJSONToFileRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	if err := marshalJSONToFile(path, map[string]string{"k": "v"}); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := st.Mode().Perm(); perm != 0o600 {
		t.Errorf("marshalJSONToFile perm = %o, want 600", perm)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]string
	if err := unmarshalJSON(data, &m); err != nil || m["k"] != "v" {
		t.Errorf("round trip = %v, %v", m, err)
	}
}

func TestMarshalJSONToFileUnmarshalableValue(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.json")
	// A channel is not JSON-serializable: marshalJSONToFile must fail and
	// must not leave a partial file.
	if err := marshalJSONToFile(path, make(chan int)); err == nil {
		t.Fatal("marshalJSONToFile on a channel succeeded, want error")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("marshalJSONToFile failure left a file behind")
	}
}

func TestMarshalJSONToFileUnwritableDir(t *testing.T) {
	path := filepath.Join(t.TempDir(), "no-such-dir", "x.json")
	if err := marshalJSONToFile(path, map[string]string{"k": "v"}); err == nil {
		t.Fatal("marshalJSONToFile into a missing dir succeeded, want error")
	}
}

func TestCopyFile(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src")
	dst := filepath.Join(dir, "dst")
	if err := os.WriteFile(src, []byte("hello world"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := copyFile(src, dst); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(dst)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "hello world" {
		t.Errorf("copied content = %q, want hello world", data)
	}
}

func TestCopyFileMissingSource(t *testing.T) {
	dir := t.TempDir()
	if err := copyFile(filepath.Join(dir, "missing"), filepath.Join(dir, "dst")); err == nil {
		t.Error("copyFile on missing source returned nil error")
	}
}

func TestDownloadFileWritesPayload(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "boot-payload")
	}))
	defer srv.Close()

	dest := filepath.Join(t.TempDir(), "artifact")
	var lastProgress float64
	if err := downloadFile(context.Background(), srv.URL, dest, func(p float64) {
		lastProgress = p
	}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(dest)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "boot-payload" {
		t.Errorf("downloaded content = %q, want boot-payload", data)
	}
	if _, err := os.Stat(dest + ".tmp"); !os.IsNotExist(err) {
		t.Error("temporary download file was not renamed away")
	}
	if lastProgress != 1.0 {
		t.Errorf("final progress = %v, want 1.0", lastProgress)
	}
}

// #53 guard: a non-2xx response must never be accepted as a boot artifact.
func TestDownloadFileRejectsNon2xx(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()

	dest := filepath.Join(t.TempDir(), "artifact")
	err := downloadFile(context.Background(), srv.URL, dest, func(float64) {})
	if err == nil {
		t.Fatal("downloadFile accepted HTTP 500")
	}
	if !strings.Contains(err.Error(), "500") {
		t.Errorf("error = %v, want it to name the HTTP status", err)
	}
	if _, statErr := os.Stat(dest); !os.IsNotExist(statErr) {
		t.Error("rejected download left a destination file behind")
	}
	if _, statErr := os.Stat(dest + ".tmp"); !os.IsNotExist(statErr) {
		t.Error("rejected download left a .tmp file behind")
	}
}

func TestDownloadFileUnwritableDestination(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "data")
	}))
	defer srv.Close()

	// Destination parent does not exist: os.Create fails and must surface
	// as an error rather than a silent success.
	dest := filepath.Join(t.TempDir(), "no-such-dir", "artifact")
	err := downloadFile(context.Background(), srv.URL, dest, func(float64) {})
	if err == nil {
		t.Fatal("downloadFile to an unwritable destination succeeded")
	}
}

func TestDownloadFileHonoursCancellation(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "data")
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancelled before the transfer starts

	dest := filepath.Join(t.TempDir(), "artifact")
	err := downloadFile(ctx, srv.URL, dest, func(float64) {})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("downloadFile with cancelled ctx = %v, want context.Canceled", err)
	}
	if _, statErr := os.Stat(dest + ".tmp"); !os.IsNotExist(statErr) {
		t.Error("cancelled download left a .tmp file behind")
	}
	if _, statErr := os.Stat(dest); !os.IsNotExist(statErr) {
		t.Error("cancelled download left a destination file behind")
	}
}
