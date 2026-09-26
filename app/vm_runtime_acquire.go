package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"wootc/internal/runtimebundle"
)

const vmRuntimeArchive = "wootc-vm-runtime.zip"

// Use the same HTTPS-only, no-ambient-proxy transport as boot artifacts. Bound
// the download before extraction so a bad server cannot consume the host disk.
func downloadVMRuntime(ctx context.Context, client *http.Client, source, destination string, progress func(float64)) error {
	if err := validateArtifactURL(source); err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return err
	}
	response, err := client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("VM runtime download: HTTP %d", response.StatusCode)
	}
	if response.ContentLength > runtimebundle.MaxArchiveBytes {
		return fmt.Errorf("VM runtime archive exceeds the size limit")
	}
	file, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	complete := false
	defer func() {
		file.Close()
		if !complete {
			os.Remove(destination)
		}
	}()
	buffer := make([]byte, 64*1024)
	var written int64
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		n, readErr := response.Body.Read(buffer)
		if n > 0 {
			written += int64(n)
			if written > runtimebundle.MaxArchiveBytes {
				return fmt.Errorf("VM runtime archive exceeds the size limit")
			}
			if _, err := file.Write(buffer[:n]); err != nil {
				return err
			}
			if progress != nil && response.ContentLength > 0 {
				progress(float64(written) / float64(response.ContentLength))
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return readErr
		}
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	complete = true
	return nil
}

type vmRuntimeAcquisition struct {
	checksums func(context.Context, string) (map[string]string, error)
	download  func(context.Context, string, string, func(float64)) error
	install   func(context.Context, string, string, string, string) error
}

// The caller owns the image lease and has audited parent. No root disk or
// lifecycle state is created or removed by this operation.
func acquireVMRuntime(ctx context.Context, parent, baseURL, publicKey string, deps vmRuntimeAcquisition, emit func(VMEvent)) error {
	if _, err := os.Lstat(filepath.Join(parent, "qemu")); !os.IsNotExist(err) {
		return fmt.Errorf("a VM runtime directory already exists; preserve it for verification or repair")
	}
	emit(VMEvent{Stage: "runtime-manifest", Message: "Checking whether this release includes Linux in a window…"})
	sums, err := deps.checksums(ctx, filepath.Join(parent, "install"))
	if err != nil {
		return err
	}
	hash, ok := sums[vmRuntimeArchive]
	if !ok {
		return fmt.Errorf("this release does not include the Linux window runtime yet; use a release that includes it")
	}
	stage, err := os.MkdirTemp(parent, ".runtime-download-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	archive := filepath.Join(stage, vmRuntimeArchive)
	emit(VMEvent{Stage: "runtime-download", Message: "Downloading the Linux window runtime…"})
	if err := deps.download(ctx, baseURL+vmRuntimeArchive, archive, func(fraction float64) {
		emit(VMEvent{Stage: "runtime-download", Percent: fraction * 100, Message: "Downloading the Linux window runtime…"})
	}); err != nil {
		return err
	}
	emit(VMEvent{Stage: "runtime-verify", Message: "Verifying and installing the Linux window runtime…"})
	if err := deps.install(ctx, archive, parent, hash, publicKey); err != nil {
		return err
	}
	return nil
}

// Interrupted downloads/extractions use reserved private prefixes. Hold the
// image lease and audit parent before calling; never remove qemu or user disks.
func cleanupVMRuntimeStaging(parent string) error {
	for _, pattern := range []string{".runtime-download-*", ".qemu-stage-*"} {
		paths, err := filepath.Glob(filepath.Join(parent, pattern))
		if err != nil {
			return err
		}
		for _, path := range paths {
			if err := os.RemoveAll(path); err != nil {
				return fmt.Errorf("could not remove interrupted runtime staging")
			}
		}
	}
	return nil
}
