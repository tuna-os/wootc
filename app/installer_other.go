//go:build !windows

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"runtime"
	"time"
)

// ── Dev stubs (non-Windows) ───────────────────────────────────────────────────
// These allow `wails dev` to run on Linux/macOS for UI development.
// None of these touch real Windows APIs.

func getSystemInfo() SystemInfo {
	return SystemInfo{
		OSVersion:   fmt.Sprintf("dev/%s (not Windows)", runtime.GOOS),
		FreeDiskGB:  240,
		TotalDiskGB: 512,
		BitLockerOn: false,
		IsUEFI:      true,
		SecureBootOn: false,
	}
}

func checkSystem() error                           { return nil }
func disableFastStartup() error                    { return nil }
func createDirectories() error                     { return os.MkdirAll("/tmp/wootc/install", 0o755) }
func createRootDisk(sizeGB int) error              {
	// Create a small placeholder file for dev testing
	path := "/tmp/wootc/disks/root.disk"
	os.MkdirAll("/tmp/wootc/disks", 0o755)
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	f.Close()
	return nil
}

func downloadDeployer(ctx context.Context, progress func(float64)) error {
	// Simulate download progress for UI dev
	for i := 0; i <= 10; i++ {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
			progress(float64(i) / 10)
			time.Sleep(200 * time.Millisecond)
		}
	}
	return nil
}

func writeGrubConfig(cfg InstallConfig) error { return nil }
func setupESP(bootloader string) error        { return nil }
func configureBCD(bootloader string) error    { return nil }

func writeVault(cfg InstallConfig) error {
	vault := map[string]string{
		"username": cfg.Username,
		"hostname": cfg.Hostname,
		"image":    cfg.ImageRef,
	}
	return marshalJSONToFile("/tmp/wootc/install/vault.json", vault)
}

func uninstall(ctx context.Context) error { return nil }
func rebootWindows() error                { return fmt.Errorf("reboot not available on %s", runtime.GOOS) }

// wootcDir returns the wootc data directory.
// On non-Windows this points to /tmp/wootc for dev/testing.
func wootcDir() string { return "/tmp/wootc" }

// ── Shared helpers (used by both platforms) ───────────────────────────────────

func marshalJSON(v any) ([]byte, error) {
	return json.MarshalIndent(v, "", "  ")
}

func marshalJSONToFile(path string, v any) error {
	data, err := marshalJSON(v)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o600)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

func downloadFile(ctx context.Context, url, dest string, progress func(float64)) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	f, err := os.Create(dest + ".tmp")
	if err != nil {
		return err
	}
	defer f.Close()

	total := resp.ContentLength
	var written int64
	buf := make([]byte, 32*1024)
	for {
		select {
		case <-ctx.Done():
			os.Remove(dest + ".tmp")
			return ctx.Err()
		default:
		}
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if _, we := f.Write(buf[:n]); we != nil {
				return we
			}
			written += int64(n)
			if total > 0 {
				progress(float64(written) / float64(total))
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
	}
	f.Close()
	return os.Rename(dest+".tmp", dest)
}

func restrictFileACL(path string) error { return nil } // no-op on Linux
