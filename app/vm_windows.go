//go:build windows

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// VM modes (SPEC §6.2): boot the installed root.disk directly in a QEMU
// window on Windows using WHPX acceleration — the user sees their Linux
// system without rebooting. Same disk, same state as the dual-boot path.
//
// QEMU-for-Windows + edk2 firmware are bundled under C:\wootc\qemu\ by the
// release. This code is the launcher + capability probe.

// VMCapability tells the GUI whether "Boot in VM" can run and why not.
type VMCapability struct {
	Available   bool   `json:"available"`
	Reason      string `json:"reason"`
	DiskPath    string `json:"diskPath"`
	Accelerator string `json:"accelerator"`
	QEMUPath    string `json:"qemuPath"`
	Bundled     bool   `json:"bundled"`
}

func qemuDir() string  { return filepath.Join(wootcDir(), "qemu") }
func qemuExe() string  { return filepath.Join(qemuDir(), "qemu-system-x86_64.exe") }
func edk2Code() string { return filepath.Join(qemuDir(), "edk2-x86_64-code.fd") }

// GetVMCapability reports whether the installed disk can be booted in a VM.
func (a *App) GetVMCapability() VMCapability {
	info := getUninstallInfo() // reuses root.disk discovery
	if !info.Found {
		return VMCapability{Available: false, Reason: "No installed TunaOS disk was found."}
	}
	qemuPath, bundled := findQEMU()
	if qemuPath == "" {
		return VMCapability{Available: false, DiskPath: info.DiskPath,
			Reason: "QEMU isn't installed. Install QEMU for Windows or reinstall wootc with the VM viewer."}
	}
	if _, err := os.Stat(edk2Code()); err != nil {
		return VMCapability{Available: false, DiskPath: info.DiskPath,
			QEMUPath: qemuPath, Bundled: bundled,
			Reason: "The VM firmware is missing. Reinstall wootc with the VM viewer."}
	}
	accelerator := availableAccelerator()
	if accelerator == "" {
		return VMCapability{Available: false, DiskPath: info.DiskPath,
			QEMUPath: qemuPath, Bundled: bundled,
			Reason: "No supported VM accelerator is available. Enable Windows Hypervisor Platform in 'Turn Windows features on or off'."}
	}
	return VMCapability{Available: true, DiskPath: info.DiskPath, Accelerator: accelerator, QEMUPath: qemuPath, Bundled: bundled}
}

func findQEMU() (string, bool) {
	if _, err := os.Stat(qemuExe()); err == nil {
		return qemuExe(), true
	}
	path, err := exec.LookPath("qemu-system-x86_64.exe")
	if err != nil {
		return "", false
	}
	return path, false
}

func availableAccelerator() string {
	if whpxAvailable() {
		return "whpx"
	}
	if haxmAvailable() {
		return "hax"
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
	args := []string{
		"-accel", cap.Accelerator,
		"-m", "4G", "-smp", "4",
		"-machine", "q35",
		"-drive", "file=" + cap.DiskPath + ",format=vhdx,if=virtio",
		"-drive", "if=pflash,format=raw,readonly=on,file=" + edk2Code(),
		"-nic", "user,hostfwd=tcp::2222-:22",
		"-display", "gtk",
		"-name", "TunaOS (VM)",
	}
	cmd := exec.Command(cap.QEMUPath, args...)
	cmd.Dir = filepath.Dir(cap.QEMUPath)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: false}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("launching QEMU: %w", err)
	}
	// Detach: the VM window outlives this call.
	go func() { _ = cmd.Wait() }()
	return nil
}

// ── §6.1 Try in VM (fresh image, two-stage headless builder) ─────────────────
//
// "Try before you install": build a bootable preview disk from an OCI image in
// a headless Alpine builder VM, then open it in an interactive QEMU window — no
// reboot, no BCD change. If the user likes it, InstallPreviewForReal() promotes
// the same disk to the permanent install (§6.4 VM-to-Native bridge).

func previewDir() string    { return filepath.Join(os.TempDir(), "wootc-preview") }
func previewRaw() string    { return filepath.Join(previewDir(), "preview.raw") }
func builderKernel() string { return filepath.Join(qemuDir(), "builder-vmlinuz") }
func builderInitrd() string { return filepath.Join(qemuDir(), "builder-initramfs.img") }

const previewIPCPort = 9099

// GetFreshVMCapability reports whether "Try in VM" (fresh build) can run. It
// needs QEMU + firmware + an accelerator (like §6.2) plus the bundled Alpine
// builder kernel/initramfs that does the OCI→disk work.
func (a *App) GetFreshVMCapability() VMCapability {
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
	if _, err := os.Stat(builderKernel()); err != nil {
		cap.Reason = "The Try-in-VM builder image isn't bundled with this build."
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

// TryInVMFresh builds preview.raw from imageRef in a headless builder VM
// (stage 1), then launches an interactive preview window (stage 2). Progress
// events are emitted on "vm:progress" from the builder's IPC channel.
// Non-blocking: returns once the interactive window has been launched.
func (a *App) TryInVMFresh(imageRef string) error {
	if imageRef == "" {
		return fmt.Errorf("no image selected")
	}
	cap := a.GetFreshVMCapability()
	if !cap.Available {
		return fmt.Errorf("%s", cap.Reason)
	}
	if err := os.MkdirAll(previewDir(), 0o755); err != nil {
		return fmt.Errorf("create workspace: %w", err)
	}
	// A 20GB sparse raw disk — instant on NTFS (truncate does not allocate).
	f, err := os.Create(previewRaw())
	if err != nil {
		return fmt.Errorf("create preview disk: %w", err)
	}
	if err := f.Truncate(20 << 30); err != nil {
		f.Close()
		return fmt.Errorf("size preview disk: %w", err)
	}
	f.Close()

	go func() {
		if err := a.runBuilderVM(imageRef, cap.Accelerator); err != nil {
			a.emitVM(VMEvent{Stage: "error", Message: err.Error()})
			return
		}
		if err := a.launchInteractivePreview(cap); err != nil {
			a.emitVM(VMEvent{Stage: "error", Message: err.Error()})
			return
		}
		a.emitVM(VMEvent{Stage: "ready", Percent: 100,
			Message: "Preview is running. Try it out — if you like it, click Install for Real."})
	}()
	return nil
}

// VMEvent is a Try-in-VM progress event (frontend listens on "vm:progress").
type VMEvent struct {
	Stage   string  `json:"stage"` // pulling | installing | booting | ready | error
	Percent float64 `json:"percent"`
	Message string  `json:"message"`
}

func (a *App) emitVM(e VMEvent) {
	if a.ctx != nil {
		runtime.EventsEmit(a.ctx, "vm:progress", e)
	}
}

// runBuilderVM launches the headless Alpine builder and blocks until it powers
// off (bootc install done) or fails. It serves an IPC socket the guest connects
// to for progress; the guest sends newline-delimited JSON {"step","pct"}.
func (a *App) runBuilderVM(imageRef, accelerator string) error {
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", previewIPCPort))
	if err != nil {
		return fmt.Errorf("open IPC socket: %w", err)
	}
	defer ln.Close()

	a.emitVM(VMEvent{Stage: "pulling", Percent: 2, Message: "Starting builder…"})

	args := []string{
		"-accel", accelerator,
		"-display", "none",
		"-m", "2G", "-smp", "2",
		"-machine", "q35",
		"-kernel", builderKernel(),
		"-initrd", builderInitrd(),
		"-append", "console=ttyS0 quiet wootc.image=" + imageRef,
		"-drive", "file=" + previewRaw() + ",format=raw,if=virtio",
		"-chardev", fmt.Sprintf("socket,id=ipc,host=127.0.0.1,port=%d", previewIPCPort),
		"-device", "virtio-serial",
		"-device", "virtserialport,chardev=ipc,name=wootc.ipc",
		"-serial", "null",
	}
	cmd := exec.Command(qemuExe(), args...)
	cmd.Dir = qemuDir()
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("launch builder VM: %w", err)
	}

	// Read guest progress until it disconnects; QEMU exits when the guest
	// powers off after a clean bootc install.
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := acceptWithTimeout(ln, 90*time.Second)
		if err != nil {
			return
		}
		defer conn.Close()
		sc := bufio.NewScanner(conn)
		for sc.Scan() {
			var msg struct {
				Step string  `json:"step"`
				Pct  float64 `json:"pct"`
			}
			if json.Unmarshal(sc.Bytes(), &msg) == nil && msg.Step != "" {
				a.emitVM(VMEvent{Stage: msg.Step, Percent: msg.Pct,
					Message: builderStepMessage(msg.Step)})
			}
		}
	}()

	waitErr := cmd.Wait()
	<-done
	if waitErr != nil {
		return fmt.Errorf("builder VM failed: %w", waitErr)
	}
	if fi, err := os.Stat(previewRaw()); err != nil || fi.Size() == 0 {
		return fmt.Errorf("builder produced no disk image")
	}
	return nil
}

func builderStepMessage(step string) string {
	switch step {
	case "pulling":
		return "Downloading the operating system image…"
	case "installing":
		return "Installing onto the preview disk…"
	case "finalizing":
		return "Finishing up…"
	}
	return step
}

// launchInteractivePreview opens the built preview.raw in a visible QEMU window.
func (a *App) launchInteractivePreview(cap VMCapability) error {
	a.emitVM(VMEvent{Stage: "booting", Percent: 95, Message: "Starting the preview…"})
	args := []string{
		"-accel", cap.Accelerator,
		"-m", "4G", "-smp", "4",
		"-machine", "q35",
		"-drive", "file=" + previewRaw() + ",format=raw,if=virtio",
		"-drive", "if=pflash,format=raw,readonly=on,file=" + edk2Code(),
		"-nic", "user,hostfwd=tcp::2223-:22",
		"-display", "gtk",
		"-name", "TunaOS (Try it out)",
	}
	cmd := exec.Command(cap.QEMUPath, args...)
	cmd.Dir = filepath.Dir(cap.QEMUPath)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: false}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("launch preview: %w", err)
	}
	go func() { _ = cmd.Wait() }()
	return nil
}

// InstallPreviewForReal promotes a tried preview disk to the permanent install
// (§6.4): move preview.raw → root.disk and arm the boot chain. Reuses the same
// setupESP/configureBCD path as a normal install so the result is identical.
func (a *App) InstallPreviewForReal(cfg InstallConfig) error {
	src := previewRaw()
	if fi, err := os.Stat(src); err != nil || fi.Size() == 0 {
		return fmt.Errorf("no preview disk to install — build one with Try in VM first")
	}
	disksDir := filepath.Join(wootcDir(), "disks")
	if err := os.MkdirAll(disksDir, 0o755); err != nil {
		return err
	}
	dst := filepath.Join(disksDir, "root.disk")
	if err := os.Rename(src, dst); err != nil {
		// Cross-volume (%TEMP% on a different drive than C:\wootc): copy+remove.
		if cerr := copyFile(src, dst); cerr != nil {
			return fmt.Errorf("promote preview disk: %w", cerr)
		}
		_ = os.Remove(src)
	}
	// Arm the boot chain against the promoted disk (no re-pull, no re-deploy).
	if err := setupESP(cfg); err != nil {
		return fmt.Errorf("set up boot files: %w", err)
	}
	if err := configureBCD(cfg.Bootloader); err != nil {
		return fmt.Errorf("configure boot entry: %w", err)
	}
	writeState(StateArmed, "", "")
	return nil
}

// acceptWithTimeout accepts one connection or returns after d.
func acceptWithTimeout(ln net.Listener, d time.Duration) (net.Conn, error) {
	if tl, ok := ln.(*net.TCPListener); ok {
		_ = tl.SetDeadline(time.Now().Add(d))
	}
	return ln.Accept()
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
