package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestRuntimeAcquisitionNeedsSignedReleaseEntryBeforeDownload(t *testing.T) {
	root := t.TempDir()
	disk := filepath.Join(root, "root.disk")
	os.WriteFile(disk, []byte("user work"), 0600)
	deps := vmRuntimeAcquisition{
		checksums: func(context.Context, string) (map[string]string, error) {
			return map[string]string{"vmlinuz": "hash"}, nil
		},
		download: func(context.Context, string, string, func(float64)) error {
			t.Fatal("downloaded an unpublished runtime")
			return nil
		},
		install: func(context.Context, string, string, string, string) error {
			t.Fatal("installed an unpublished runtime")
			return nil
		},
	}
	if err := acquireVMRuntime(context.Background(), root, "https://release.invalid/", "key", deps, func(VMEvent) {}); err == nil {
		t.Fatal("unpublished release appeared successful")
	}
	data, err := os.ReadFile(disk)
	if err != nil || string(data) != "user work" {
		t.Fatal("acquisition touched the user disk")
	}
}
func TestRuntimeAcquisitionPassesAuthenticatedHashAndCleansDownload(t *testing.T) {
	root := t.TempDir()
	var archive string
	installed := false
	deps := vmRuntimeAcquisition{
		checksums: func(context.Context, string) (map[string]string, error) {
			return map[string]string{vmRuntimeArchive: "authenticated-hash"}, nil
		},
		download: func(ctx context.Context, source, dest string, progress func(float64)) error {
			archive = dest
			if source != "https://release.invalid/"+vmRuntimeArchive {
				t.Fatal(source)
			}
			return os.WriteFile(dest, []byte("archive"), 0600)
		},
		install: func(ctx context.Context, path, parent, hash, key string) error {
			if path != archive || parent != root || hash != "authenticated-hash" || key != "embedded-key" {
				t.Fatal("authentication identity changed")
			}
			installed = true
			return nil
		},
	}
	if err := acquireVMRuntime(context.Background(), root, "https://release.invalid/", "embedded-key", deps, func(VMEvent) {}); err != nil {
		t.Fatal(err)
	}
	if !installed {
		t.Fatal("no install")
	}
	if _, err := os.Stat(archive); !os.IsNotExist(err) {
		t.Fatal("staged download retained")
	}
}
func TestRuntimeDownloadRejectsErrorOversizeAndPreservesExisting(t *testing.T) {
	for _, mode := range []string{"error", "oversize", "ok"} {
		t.Run(mode, func(t *testing.T) {
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch mode {
				case "error":
					w.WriteHeader(404)
				case "oversize":
					w.Header().Set("Content-Length", fmt.Sprint(1<<30))
				default:
					fmt.Fprint(w, "archive")
				}
			}))
			defer server.Close()
			dest := filepath.Join(t.TempDir(), "runtime.zip")
			err := downloadVMRuntime(context.Background(), server.Client(), server.URL, dest, nil)
			if (err == nil) != (mode == "ok") {
				t.Fatalf("mode %s: %v", mode, err)
			}
			if mode != "ok" {
				if _, err := os.Stat(dest); !os.IsNotExist(err) {
					t.Fatal("bad response left archive")
				}
				return
			}
			if err := downloadVMRuntime(context.Background(), server.Client(), server.URL, dest, nil); err == nil {
				t.Fatal("existing archive overwritten")
			}
			data, _ := os.ReadFile(dest)
			if string(data) != "archive" {
				t.Fatal("existing bytes changed")
			}
		})
	}
}

func TestRuntimeCrashCleanupPreservesPublishedRuntimeAndUserDisk(t *testing.T) {
	root := t.TempDir()
	for _, dir := range []string{".runtime-download-interrupted", ".qemu-stage-interrupted", "qemu", "disks"} {
		os.Mkdir(filepath.Join(root, dir), 0700)
		os.WriteFile(filepath.Join(root, dir, "sentinel"), []byte("keep"), 0600)
	}
	if err := cleanupVMRuntimeStaging(root); err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{"qemu", "disks"} {
		data, err := os.ReadFile(filepath.Join(root, dir, "sentinel"))
		if err != nil || string(data) != "keep" {
			t.Fatalf("cleanup changed %s", dir)
		}
	}
	for _, dir := range []string{".runtime-download-interrupted", ".qemu-stage-interrupted"} {
		if _, err := os.Stat(filepath.Join(root, dir)); !os.IsNotExist(err) {
			t.Fatalf("retained %s", dir)
		}
	}
}

func TestRuntimeDownloadCancellationRemovesPartial(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "1000000")
		fmt.Fprint(w, "partial")
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	dest := filepath.Join(t.TempDir(), "runtime.zip")
	observed := false
	err := downloadVMRuntime(ctx, server.Client(), server.URL, dest, func(float64) { observed = true; cancel() })
	if err == nil || !observed {
		t.Fatalf("cancellation did not follow actual bytes: observed=%v err=%v", observed, err)
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatal("partial archive retained")
	}
}
