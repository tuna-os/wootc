//go:build windows

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// prepareVMNativeExport performs only the non-destructive part of promotion.
// The image remains a stopped VM; no host ESP, firmware or BCD is changed.
func (a *App) prepareVMNativeExport() (resultErr error) {
	cap := a.vmRuntimeCapability()
	if !cap.Available {
		return fmt.Errorf("%s", cap.Reason)
	}
	metadata, err := readLocalMetadata(filepath.Join(qemuDir(), "builder-protocol.json"), 64<<10)
	if err != nil {
		return err
	}
	var protocol struct {
		Operations []string `json:"operations"`
	}
	if err = json.Unmarshal(metadata, &protocol); err != nil {
		return err
	}
	supported := false
	for _, operation := range protocol.Operations {
		if operation == "export-boot" {
			supported = true
		}
	}
	if !supported {
		return fmt.Errorf("this signed runtime does not support read-only native boot export; install a runtime with export-boot support")
	}
	cap = a.probeVMRuntime(cap)
	if !cap.Available {
		return fmt.Errorf("%s", cap.Reason)
	}
	release, err := acquireVMLock(managedVMRootDisk())
	if err != nil {
		return err
	}
	defer release()
	if err := cleanupVMPromotionStaging(previewDir()); err != nil {
		return err
	}
	state, err := readVMState(vmStatePath(wootcDir()))
	if err != nil {
		return err
	}
	if state.Phase != vmStopped {
		return fmt.Errorf("native preparation requires verified clean guest shutdown; the disk is %s", state.Phase)
	}
	if err := vmLaunchAllowed(state, managedVMRootDisk()); err != nil {
		return err
	}
	if err := verifyVMDiskReleased(state.DiskPath); err != nil {
		return err
	}
	hostUUID, err := ntfsHostUUID(strings.TrimSuffix(filepath.VolumeName(state.DiskPath), ":"))
	if err != nil {
		return err
	}
	if available, err := vmFreeBytes(wootcDir()); err != nil || available < vmWindowsReserveBytes+uint64(vmBootExportLimit)*2 {
		return fmt.Errorf("native boot preparation needs the Windows reserve plus 1 GiB for its verified export")
	}
	stage, err := os.MkdirTemp(previewDir(), ".promotion-export-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	state.RunID = newVMID()
	journalPath := filepath.Join(previewDir(), "promotion.json")
	record := vmPromotionRecord{InstallID: state.InstallID, DiskID: state.DiskID, RunID: state.RunID, Phase: "exporting"}
	if err := writeVMPromotionRecord(journalPath, record); err != nil {
		return err
	}
	defer func() {
		if resultErr != nil {
			// No writable attachment or host boot changes exist to undo. A
			// failed/interrupted export preserves the original VM and firmware.
			record.Phase = "export-failed"
			record.Error = resultErr.Error()
			if err := writeVMPromotionRecord(journalPath, record); err != nil {
				resultErr = fmt.Errorf("%v; record promotion failure: %w", resultErr, err)
			}
		}
	}()
	archivePath := filepath.Join(stage, "boot-inputs.tar")
	progressPath := filepath.Join(stage, "progress.log")
	args := []string{"-accel", cap.Accelerator, "-display", "none", "-m", "3072", "-smp", "2", "-machine", "q35", "-cpu", "max",
		"-kernel", builderKernel(), "-initrd", builderInitrd(),
		"-append", "console=ttyS0 quiet wootc.image=" + state.Image + " wootc.run_id=" + state.RunID + " wootc.install_id=" + state.InstallID + " wootc.operation=export-boot wootc.disk_id=" + state.DiskID,
		"-drive", vmDiskDrive(state.DiskPath) + ",serial=wootc-root,readonly=on",
		"-nic", "none", "-device", "virtio-serial", "-chardev", "file,id=ipc,path=" + qemuEscape(progressPath),
		"-device", "virtserialport,chardev=ipc,name=wootc.ipc", "-chardev", "file,id=export,path=" + qemuEscape(archivePath),
		"-device", "virtserialport,chardev=export,name=wootc.export", "-serial", "file:" + filepath.Join(stage, "serial.log")}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
	defer cancel()
	ctx, stopSpaceGuard := guardVMFreeSpace(ctx, vmWindowsReserveBytes, 100*time.Millisecond, func() (uint64, error) {
		if info, err := os.Stat(archivePath); err == nil && info.Size() > vmBootExportLimit {
			return 0, fmt.Errorf("installed boot export exceeds its size limit")
		}
		return vmFreeBytes(wootcDir())
	})
	defer stopSpaceGuard()
	done := make(chan struct{})
	a.vmMu.Lock()
	a.vmCancel = cancel
	a.vmPrepareDone = done
	a.vmMu.Unlock()
	defer close(done)
	defer func() {
		a.vmMu.Lock()
		a.vmCancel = nil
		a.vmPrepareDone = nil
		a.vmMu.Unlock()
	}()
	cmd := exec.CommandContext(ctx, cap.QEMUPath, args...)
	cmd.Dir = filepath.Dir(cap.QEMUPath)
	cmd.Env = vmProcessEnvironment(cmd.Dir, stage)
	cmd.SysProcAttr = vmProcessAttributes()
	stderr, err := os.OpenFile(filepath.Join(stage, "qemu-error.log"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer stderr.Close()
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	job, err := ownVMProcess(cmd)
	if err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return err
	}
	defer job.Close()
	if err := cmd.Wait(); err != nil {
		if cause := context.Cause(ctx); cause != nil {
			return cause
		}
		return fmt.Errorf("read-only native export failed: %w", err)
	}
	if cause := context.Cause(ctx); cause != nil {
		return cause
	}
	progress, err := os.Open(progressPath)
	if err != nil {
		return err
	}
	result := readBuilderProgress(progress, a.emitVM)
	progress.Close()
	if err := result.verify(nil); err != nil {
		return err
	}
	archive, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer archive.Close()
	info, err := archive.Stat()
	if err != nil || info.Size() > vmBootExportLimit {
		return fmt.Errorf("installed boot export exceeds its size limit")
	}
	output := filepath.Join(stage, "verified")
	if err := os.Mkdir(output, 0700); err != nil {
		return err
	}
	if _, err := unpackVMBootExport(archive, output, state, hostUUID); err != nil {
		return err
	}
	published := filepath.Join(previewDir(), "native-boot-"+state.RunID)
	if err := os.Rename(output, published); err != nil {
		return err
	}
	record.Phase = "boot-inputs-verified"
	record.ExportPath = published
	return writeVMPromotionRecord(journalPath, record)
}
