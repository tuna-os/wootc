//go:build windows

package main

import (
	"context"
	"fmt"
	"golang.org/x/sys/windows"
	"os"
	"path/filepath"
	"time"
	"wootc/internal/runtimebundle"
)

// InstallVMRuntime starts only after explicit selection in the GUI or RPC.
// It never replaces an existing runtime and never changes a Linux disk.
func (a *App) InstallVMRuntime() error {
	if previewMode() {
		return fmt.Errorf("runtime installation is unavailable in the UI test harness")
	}
	root := wootcDir()
	if err := prepareTrustedStateTree(root); err != nil {
		return err
	}
	release, err := acquireVMLock(managedVMRootDisk())
	if err != nil {
		return err
	}
	if _, err := os.Lstat(filepath.Join(root, "qemu")); !os.IsNotExist(err) {
		release()
		return fmt.Errorf("a VM runtime directory already exists; preserve it for verification or repair")
	}
	if err := cleanupVMRuntimeStaging(root); err != nil {
		release()
		return err
	}
	rootPointer, err := windows.UTF16PtrFromString(root)
	if err != nil {
		release()
		return err
	}
	var available, total, free uint64
	if err := windows.GetDiskFreeSpaceEx(rootPointer, &available, &total, &free); err != nil {
		release()
		return err
	}
	if available < 2<<30 {
		release()
		return fmt.Errorf("runtime setup needs at least 2 GB free for its download, verified files and Windows reserve")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	done := make(chan struct{})
	a.vmMu.Lock()
	a.vmCancel = cancel
	a.vmPrepareDone = done
	a.vmMu.Unlock()
	go func() {
		defer close(done)
		defer cancel()
		defer release()
		defer func() { a.vmMu.Lock(); a.vmCancel = nil; a.vmPrepareDone = nil; a.vmMu.Unlock() }()
		deps := vmRuntimeAcquisition{checksums: fetchArtifactChecksums, download: func(ctx context.Context, source, dest string, progress func(float64)) error {
			return downloadVMRuntime(ctx, artifactClient, source, dest, progress)
		}, install: runtimebundle.Install}
		if err := acquireVMRuntime(ctx, root, deployerBaseURL(), artifactPublicKey, deps, a.emitVM); err != nil {
			a.emitVM(VMEvent{Stage: "error", Message: err.Error()})
			return
		}
		a.emitVM(VMEvent{Stage: "runtime-ready", Message: "The runtime is installed. Checking whether this PC can run Linux in a window…"})
	}()
	return nil
}
