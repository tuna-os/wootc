//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

func (a *App) GetVMState() VMState {
	if previewMode() {
		return VMState{SchemaVersion: 1, Phase: "unavailable", Error: "VM execution is unavailable in the UI test harness."}
	}
	a.vmMu.Lock()
	defer a.vmMu.Unlock()
	if a.vmSession != nil {
		return a.vmSession.snapshot()
	}
	if a.vmCancel == nil {
		if err := prepareTrustedStateTree(wootcDir()); err != nil {
			return VMState{SchemaVersion: 1, Phase: vmRecovery, Error: err.Error()}
		}
		if release, err := acquireVMLock(managedVMRootDisk()); err == nil {
			cleanupErr := removeVMAccountInputs(previewDir())
			release()
			if cleanupErr != nil {
				return VMState{SchemaVersion: 1, Phase: vmRecovery, Error: cleanupErr.Error()}
			}
		}
	}
	state, err := readVMState(vmStatePath(wootcDir()))
	if os.IsNotExist(err) {
		return VMState{SchemaVersion: 1, Phase: "absent"}
	}
	if err != nil {
		return VMState{SchemaVersion: 1, Phase: vmRecovery, Error: err.Error()}
	}
	switch state.Phase {
	case vmRunning, vmStarting, vmStopping, vmPreparing:
		if a.vmCancel != nil {
			return state
		}
		state.Phase = vmRecovery
		state.Error = "The previous VM session did not record a clean stop. Its disk is preserved; check it before reuse."
	}
	state.DesktopReady = false
	return state
}

func (a *App) StopVM() error {
	a.vmMu.Lock()
	session := a.vmSession
	a.vmMu.Unlock()
	if session == nil {
		return fmt.Errorf("no VM is owned by this engine; inspect its recorded state before reuse")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	return session.stop(ctx)
}

// ForceStopVM is a separate explicit action. It never changes the image back
// to ready: an interrupted filesystem needs its own recovery check.
func (a *App) ForceStopVM() error {
	a.vmMu.Lock()
	session := a.vmSession
	cancel := a.vmCancel
	done := a.vmPrepareDone
	a.vmMu.Unlock()
	if cancel != nil {
		cancel()
		if done != nil {
			<-done
		}
		a.vmMu.Lock()
		session = a.vmSession
		a.vmMu.Unlock()
		if session != nil {
			return session.force()
		}
		return nil
	}
	if session == nil {
		return fmt.Errorf("no active VM is owned by this engine")
	}
	return session.force()
}

func (a *App) shutdownVM() {
	a.vmMu.Lock()
	cancel := a.vmCancel
	done := a.vmPrepareDone
	a.vmMu.Unlock()
	if cancel != nil {
		cancel()
		if done != nil {
			<-done
		}
	}
	a.vmMu.Lock()
	session := a.vmSession
	a.vmMu.Unlock()
	if session != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		err := session.stop(ctx)
		cancel()
		if err != nil {
			_ = session.force()
		}
	}
}

func managedVMRootDisk() string { return filepath.Join(wootcDir(), "disks", "root.disk") }
func managedVMVars() string     { return filepath.Join(wootcDir(), "vm", "firmware-vars.fd") }
func edk2VarsTemplate() string  { return filepath.Join(qemuDir(), "share", "edk2-i386-vars.fd") }

func createVMVars() error {
	if _, err := os.Stat(managedVMVars()); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}
	data, err := os.ReadFile(edk2VarsTemplate())
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(managedVMVars()), ".firmware-vars-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), managedVMVars())
}

// launchManagedDesktop consumes the already-acquired image lease. Every launch
// reuses both the raw image and firmware variables; neither is recreated.
func (a *App) launchManagedDesktop(cap VMCapability, state VMState, release func()) error {
	if err := vmLaunchAllowed(state, managedVMRootDisk()); err != nil {
		return err
	}
	if err := verifyVMDiskReleased(state.DiskPath); err != nil {
		return err
	}
	if err := createVMVars(); err != nil {
		return fmt.Errorf("prepare persistent VM firmware: %w", err)
	}
	memory, cpus, err := vmResourceBudget(getSystemInfo().RAMGB)
	if err != nil {
		return err
	}
	args := []string{"-accel", cap.Accelerator, "-machine", "q35", "-cpu", "max", "-m", fmt.Sprint(memory), "-smp", fmt.Sprint(cpus),
		"-drive", vmDiskDrive(state.DiskPath),
		"-drive", "if=pflash,format=raw,readonly=on,file=" + qemuEscape(edk2Code()),
		"-drive", "if=pflash,format=raw,file=" + qemuEscape(managedVMVars()),
		"-nic", "user", "-display", "gtk,window-close=off,show-menubar=off", "-qmp", "stdio", "-monitor", "none",
		"-name", effectiveBranding().Name + " (VM)"}
	cmd := exec.Command(cap.QEMUPath, args...)
	cmd.Dir = filepath.Dir(cap.QEMUPath)
	cmd.Env = vmProcessEnvironment(cmd.Dir, previewDir())
	cmd.SysProcAttr = vmProcessAttributes()
	log, err := os.OpenFile(filepath.Join(wootcDir(), "vm", "qemu.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	cmd.Stderr = log
	session, err := startManagedVM(cmd, vmStatePath(wootcDir()), state, release, ownVMProcess)
	if err != nil {
		log.Close()
		return err
	}
	a.vmMu.Lock()
	a.vmSession = session
	a.vmMu.Unlock()
	go func() {
		<-session.done
		log.Close()
		state := session.snapshot()
		a.emitVM(VMEvent{Stage: state.Phase, Message: state.Error})
	}()
	return nil
}
