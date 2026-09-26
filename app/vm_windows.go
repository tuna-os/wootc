//go:build windows

package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// VM modes (SPEC §6.2): boot the installed root.disk directly in a QEMU
// window on Windows using WHPX acceleration — the user sees their Linux
// system without rebooting. Same disk, same state as the dual-boot path.
//
// The signed QEMU runtime and firmware are staged under C:\wootc\qemu.
// Standard releases do not yet supply that bundle; see docs/managed-vm.md.

// VMCapability tells the GUI whether "Boot in VM" can run and why not.
type VMCapability struct {
	Available   bool   `json:"available"`
	Reason      string `json:"reason"`
	DiskPath    string `json:"diskPath"`
	Accelerator string `json:"accelerator"`
	QEMUPath    string `json:"qemuPath"`
	Bundled     bool   `json:"bundled"`
	ProbeStatus string `json:"probeStatus"`
}

func qemuDir() string  { return filepath.Join(wootcDir(), "qemu") }
func qemuExe() string  { return filepath.Join(qemuDir(), "qemu-system-x86_64.exe") }
func edk2Code() string { return filepath.Join(qemuDir(), "share", "edk2-x86_64-code.fd") }

// GetVMCapability reports whether the installed disk can be booted in a VM.
func (a *App) GetVMCapability() VMCapability {
	state := a.GetVMState()
	if state.Phase != vmReady && state.Phase != vmStopped {
		return VMCapability{DiskPath: state.DiskPath, Reason: "No verified, stopped VM installation is ready. " + state.Error}
	}
	cap := a.vmRuntimeCapability()
	cap.DiskPath = state.DiskPath
	if cap.Available {
		cap = a.probeVMRuntime(cap)
	}
	return cap
}

func findQEMU() (string, bool) {
	if info, err := os.Stat(qemuExe()); err == nil && !info.IsDir() {
		return qemuExe(), true
	}
	return "", false // never execute an arbitrary elevated binary from PATH
}

func availableAccelerator() string {
	if whpxAvailable() {
		return "whpx"
	}
	return ""
}

// BootInVM launches QEMU on the installed root.disk in its own window
// (SPEC §6.2). Changes made in the VM persist — it's the same filesystem
// as the dual-boot install. Returns once QEMU has started (non-blocking).
func (a *App) BootInVM() error {
	cap := a.GetVMCapability()
	if !cap.Available {
		return fmt.Errorf("%s", cap.Reason)
	}
	if err := prepareTrustedStateTree(wootcDir()); err != nil {
		return err
	}
	release, err := acquireVMLock(managedVMRootDisk())
	if err != nil {
		return err
	}
	if err := removeVMAccountInputs(previewDir()); err != nil {
		release()
		return err
	}
	state, err := readVMState(vmStatePath(wootcDir()))
	if err == nil {
		err = a.launchManagedDesktop(cap, state, release)
	}
	if err != nil {
		release()
	}
	return err
}

// ── §6.1 Try in VM (fresh image, two-stage headless builder) ─────────────────
//
// "Try before you install": build a bootable preview disk from an OCI image in
// a headless Alpine builder VM, then open it in an interactive QEMU window — no
// reboot, no BCD change. Native promotion remains gated until the same-image
// lifecycle and shutdown contract in ADR 0004 is proven.

func previewDir() string    { return filepath.Join(wootcDir(), "vm") }
func previewRaw() string    { return managedVMRootDisk() }
func builderKernel() string { return filepath.Join(qemuDir(), "builder-vmlinuz") }
func builderInitrd() string { return filepath.Join(qemuDir(), "builder-initramfs.img") }

// GetFreshVMCapability reports whether "Try in VM" (fresh build) can run. It
// needs QEMU + firmware + an accelerator (like §6.2) plus the bundled Alpine
// builder kernel/initramfs that does the OCI→disk work.
// VM-first is the required product direction (ADR 0004). Current standard
// releases still lack a proven runtime/builder bundle, so this capability must
// remain unavailable unless those assets are actually present.
func (a *App) vmRuntimeCapability() VMCapability {
	if previewMode() {
		return VMCapability{Reason: "VM execution is unavailable in the UI test harness."}
	}
	if err := prepareTrustedStateTree(wootcDir()); err != nil {
		return VMCapability{Reason: err.Error()}
	}
	if err := verifyVMRuntime(qemuDir(), artifactPublicKey); err != nil {
		return VMCapability{Reason: err.Error()}
	}
	qemuPath, bundled := findQEMU()
	cap := VMCapability{QEMUPath: qemuPath, Bundled: bundled}
	if qemuPath == "" {
		cap.Reason = "QEMU isn't installed. Reinstall wootc with the VM viewer."
		return cap
	}
	if _, err := os.Stat(edk2Code()); err != nil {
		cap.Reason = "The VM firmware is missing. Reinstall wootc with the VM viewer."
		return cap
	}
	if _, err := os.Stat(edk2VarsTemplate()); err != nil {
		cap.Reason = "The persistent VM firmware template is missing."
		return cap
	}
	if _, _, err := vmResourceBudget(getSystemInfo().RAMGB); err != nil {
		cap.Reason = err.Error()
		return cap
	}
	if acc := availableAccelerator(); acc != "" {
		cap.Available = true
		cap.Accelerator = acc
	} else {
		cap.Reason = "No VM accelerator available. Enable Windows Hypervisor Platform."
	}
	return cap
}

func (a *App) GetFreshVMCapability() VMCapability {
	cap := a.vmRuntimeCapability()
	if getSystemInfo().RAMGB < 6 {
		cap.Available = false
		cap.Reason = "This preparation profile needs at least 6 GB RAM so Windows retains memory. A lighter profile is not verified yet."
		return cap
	}
	if !cap.Available {
		return cap
	}
	if _, err := os.Stat(builderKernel()); err != nil {
		cap.Available = false
		cap.Reason = "The Try-in-VM builder image isn't bundled with this build."
		return cap
	}
	if _, err := os.Stat(builderInitrd()); err != nil {
		cap.Available = false
		cap.Reason = "The VM builder initramfs is missing."
		return cap
	}
	return a.probeVMRuntime(cap)
}

// TryInVMFresh provisions one persistent raw disk, then launches its VM.
// Completion needs a matching helper receipt and actual disk identity.
// Non-blocking: returns after the worker starts, before provisioning completes.
func (a *App) TryInVMFresh(imageRef string) error {
	return fmt.Errorf("Linux account details are required; use PrepareVM")
}

func (a *App) PrepareVM(cfg VMInstallConfig) error {
	if err := validateVMInstallConfig(cfg); err != nil {
		return err
	}
	hash, err := hashPassword(cfg.Password)
	cfg.Password = ""
	if err != nil {
		return fmt.Errorf("could not prepare the Linux password")
	}
	imageRef := cfg.ImageRef
	cap := a.GetFreshVMCapability()
	if !cap.Available {
		return fmt.Errorf("%s", cap.Reason)
	}
	if err := prepareTrustedStateTree(wootcDir()); err != nil {
		return err
	}
	release, err := acquireVMLock(managedVMRootDisk())
	if err != nil {
		return err
	}
	if err := removeVMAccountInputs(previewDir()); err != nil {
		release()
		return err
	}
	if _, err := os.Lstat(managedVMRootDisk()); !os.IsNotExist(err) {
		release()
		return fmt.Errorf("an existing Linux disk is preserved; start that VM or explicitly remove it before preparing another")
	}
	if _, err := os.Lstat(vmStatePath(wootcDir())); !os.IsNotExist(err) {
		release()
		return fmt.Errorf("an existing VM installation record needs review before creating a new disk")
	}
	if err := os.MkdirAll(previewDir(), 0700); err != nil {
		release()
		return err
	}
	if err := os.MkdirAll(filepath.Dir(managedVMRootDisk()), 0700); err != nil {
		release()
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Hour)
	done := make(chan struct{})
	a.vmMu.Lock()
	a.vmCancel = cancel
	a.vmPrepareDone = done
	a.vmMu.Unlock()
	go func() {
		defer close(done)
		defer cancel()
		defer func() { a.vmMu.Lock(); a.vmCancel = nil; a.vmPrepareDone = nil; a.vmMu.Unlock() }()
		state := VMState{SchemaVersion: 1, InstallID: newVMID(), RunID: newVMID(), Image: imageRef, DiskPath: managedVMRootDisk(), Phase: vmPreparing, Username: cfg.Username, AccountOutcome: "created"}
		err := writeVMState(vmStatePath(wootcDir()), state)
		if err == nil {
			state.Image, err = resolveVMImage(ctx, imageRef)
		}
		if err == nil {
			err = writeVMState(vmStatePath(wootcDir()), state)
		}
		if err == nil {
			err = createVMImageFiles()
		}
		if err == nil {
			err = a.runBuilderVM(ctx, cap, &state, hash)
			hash = ""
		}
		if err == nil {
			state.Phase = vmReady
			err = writeVMState(vmStatePath(wootcDir()), state)
		}
		if err == nil {
			err = ctx.Err()
		}
		if err == nil {
			err = a.launchManagedDesktop(cap, state, release)
		}
		if err != nil {
			if state.DiskID == "" {
				state.Phase = vmFailed
			} else {
				// Preparation completed. Preserve its ready state if launch
				// failed before QEMU touched the disk, or its recovery record
				// if control setup failed after process creation.
				if recorded, readErr := readVMState(vmStatePath(wootcDir())); readErr == nil {
					state = recorded
				}
				if state.Phase == vmStarting {
					state.Phase = vmRecovery
				}
			}
			state.Error = err.Error()
			_ = writeVMState(vmStatePath(wootcDir()), state)
			release()
			a.emitVM(VMEvent{Stage: "error", Message: err.Error()})
			return
		}
		a.emitVM(VMEvent{Stage: "started", Message: "Your persistent Linux VM is running. Desktop and account readiness are not yet verified."})
	}()
	return nil
}

func newVMID() string {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(id[:])
}

func resolveVMImage(ctx context.Context, image string) (string, error) {
	host, repo, ref, err := registryRef(image)
	if err != nil {
		return "", err
	}
	puller := &ociPuller{client: &http.Client{Timeout: 60 * time.Second}, host: host, repo: repo}
	if err = puller.authorize(ctx); err != nil {
		return "", err
	}
	_, digest, err := puller.fetchManifest(ctx, ref)
	if err != nil {
		return "", err
	}
	return host + "/" + repo + "@" + digest, nil
}

func (a *App) runBuilderVM(ctx context.Context, cap VMCapability, state *VMState, passwordHash string) (resultErr error) {
	accountPath, err := writeVMAccountInput(previewDir(), vmAccountInput{SchemaVersion: 1, RunID: state.RunID, InstallID: state.InstallID, Username: state.Username, PasswordHash: passwordHash})
	if err != nil {
		return err
	}
	defer func() {
		if err := os.Remove(accountPath); err != nil && !os.IsNotExist(err) && resultErr == nil {
			resultErr = fmt.Errorf("could not remove private account input")
		}
	}()
	logPath := filepath.Join(previewDir(), state.RunID+"-builder.log")
	serialPath := filepath.Join(previewDir(), state.RunID+"-serial.log")
	a.emitVM(VMEvent{Stage: "pulling", Message: "Preparing your persistent Linux system. Windows will remain available."})
	args := []string{"-accel", cap.Accelerator, "-display", "none", "-m", "3072", "-smp", "2", "-machine", "q35", "-cpu", "max",
		"-kernel", builderKernel(), "-initrd", builderInitrd(),
		"-append", "console=ttyS0 quiet wootc.image=" + state.Image + " wootc.run_id=" + state.RunID + " wootc.install_id=" + state.InstallID + " wootc.account_mode=create",
		"-fw_cfg", "name=opt/wootc/install,file=" + qemuEscape(accountPath),
		"-drive", vmDiskDrive(state.DiskPath) + ",serial=wootc-root",
		"-drive", vmDiskDrive(filepath.Join(previewDir(), "scratch.disk")) + ",serial=wootc-scratch",
		"-nic", "user", "-chardev", "file,id=ipc,path=" + qemuEscape(logPath), "-device", "virtio-serial",
		"-device", "virtserialport,chardev=ipc,name=wootc.ipc", "-serial", "file:" + serialPath}
	cmd := exec.CommandContext(ctx, cap.QEMUPath, args...)
	cmd.Dir = filepath.Dir(cap.QEMUPath)
	cmd.Env = vmProcessEnvironment(cmd.Dir, previewDir())
	cmd.SysProcAttr = vmProcessAttributes()
	stderr, err := os.OpenFile(filepath.Join(previewDir(), state.RunID+"-builder-error.log"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer stderr.Close()
	cmd.Stderr = stderr
	if err = cmd.Start(); err != nil {
		return err
	}
	job, err := ownVMProcess(cmd)
	if err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return err
	}
	defer job.Close()
	if err = cmd.Wait(); err != nil {
		return fmt.Errorf("VM preparation did not complete: %w", err)
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	log, err := os.Open(logPath)
	if err != nil {
		return err
	}
	defer log.Close()
	receipt, err := verifyVMBuilderReceipt(log, *state)
	if err != nil {
		return err
	}
	state.DiskID = receipt.DiskID
	return nil
}

// InstallPreviewForReal remains unavailable until VM shutdown, exclusive disk
// ownership and same-image native boot compatibility are proven (ADR 0004).
func (a *App) InstallPreviewForReal(cfg InstallConfig) error {
	return fmt.Errorf("native promotion is not available yet: keep your VM disk; shutdown and boot compatibility checks are still required")
}

func haxmAvailable() bool {
	out, err := runPowerShellOutput(`(Get-Service -Name intelhaxm -ErrorAction SilentlyContinue).Status`)
	return err == nil && strings.TrimSpace(out) == "Running"
}

// whpxAvailable checks whether the Windows Hypervisor Platform feature is
// enabled (required for QEMU's whpx accelerator).
func whpxAvailable() bool {
	out, err := runPowerShellOutput(
		`(Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -ErrorAction SilentlyContinue).State`)
	if err != nil {
		return false
	}
	return strings.TrimSpace(out) == "Enabled"
}
