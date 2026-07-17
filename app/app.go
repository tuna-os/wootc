package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// ── Data types ────────────────────────────────────────────────────────────────

// Image is one bootable variant from the catalog.
type Image struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Emoji       string `json:"emoji"`
	Base        string `json:"base"`
	Desktop     string `json:"desktop"`
	DesktopName string `json:"desktopName"`
	ImageRef    string `json:"imageRef"`
	Description string `json:"description"`
}

// InstallConfig is the parameters collected on Screen 1.
type InstallConfig struct {
	ImageRef   string `json:"imageRef"`
	DiskSizeGB int    `json:"diskSizeGB"`
	Username   string `json:"username"`
	Password   string `json:"password"`
	Hostname   string `json:"hostname"`
	Bootloader string `json:"bootloader"` // "grub2" | "systemd-boot"
}

// ProgressEvent is emitted during install for the frontend progress bar.
type ProgressEvent struct {
	Step    string  `json:"step"`
	Message string  `json:"message"`
	Percent float64 `json:"percent"`
	Done    bool    `json:"done"`
	Error   string  `json:"error,omitempty"`
}

// InstallStatus is the current state of a running or completed install.
type InstallStatus struct {
	Running  bool   `json:"running"`
	Done     bool   `json:"done"`
	Error    string `json:"error,omitempty"`
	Existing bool   `json:"existing"` // root.vhdx already found on startup
}

// SystemInfo describes the host Windows environment.
type SystemInfo struct {
	OSVersion     string  `json:"osVersion"`
	FreeDiskGB    float64 `json:"freeDiskGB"`
	TotalDiskGB   float64 `json:"totalDiskGB"`
	BitLockerOn   bool    `json:"bitLockerOn"`
	FastStartupOn bool    `json:"fastStartupOn"`
	IsUEFI        bool    `json:"isUefi"`
	SecureBootOn  bool    `json:"secureBootOn"`
}

// ── App struct ────────────────────────────────────────────────────────────────

// App is the Wails application backend. All exported methods are callable
// from the frontend via the generated wailsjs bindings.
type App struct {
	ctx    context.Context
	status InstallStatus
	cancel context.CancelFunc
}

func NewApp() *App {
	return &App{}
}

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	// Check for existing install on startup — routes to Control Panel screen.
	a.status.Existing = a.existingInstallFound()
}

func (a *App) shutdown(ctx context.Context) {
	if a.cancel != nil {
		a.cancel()
	}
}

// ── Catalog ───────────────────────────────────────────────────────────────────

// GetImages returns the flat list of installable images from the embedded
// catalog. If C:\wootc\images.json exists it takes precedence (custom
// deployments / enterprise override).
func (a *App) GetImages() ([]Image, error) {
	// In production: load from embedded data/images.json and/or C:\wootc\images.json
	// For now: return the built-in TunaOS catalog.
	catalog := []Image{
		{
			ID: "yellowfin-gnome", Name: "Yellowfin", Emoji: "🐠",
			Base: "AlmaLinux Kitten 10", Desktop: "gnome", DesktopName: "GNOME",
			ImageRef:    "ghcr.io/tuna-os/yellowfin:gnome",
			Description: "Modern GNOME desktop on Enterprise Linux. Stable and reliable.",
		},
		{
			ID: "yellowfin-kde", Name: "Yellowfin", Emoji: "🐠",
			Base: "AlmaLinux Kitten 10", Desktop: "kde", DesktopName: "KDE Plasma",
			ImageRef:    "ghcr.io/tuna-os/yellowfin:kde",
			Description: "KDE Plasma desktop on Enterprise Linux.",
		},
		{
			ID: "bonito-gnome", Name: "Bonito", Emoji: "🎣",
			Base: "Fedora 44", Desktop: "gnome", DesktopName: "GNOME",
			ImageRef:    "ghcr.io/tuna-os/bonito:gnome",
			Description: "Cutting-edge GNOME on Fedora. Latest upstream packages.",
		},
		{
			ID: "bonito-kde", Name: "Bonito", Emoji: "🎣",
			Base: "Fedora 44", Desktop: "kde", DesktopName: "KDE Plasma",
			ImageRef:    "ghcr.io/tuna-os/bonito:kde",
			Description: "KDE Plasma on Fedora. Rolling updates, familiar interface.",
		},
		{
			ID: "marlin-gnome", Name: "Marlin", Emoji: "🚀",
			Base: "Arch Linux", Desktop: "gnome", DesktopName: "GNOME",
			ImageRef:    "ghcr.io/tuna-os/marlin:gnome",
			Description: "GNOME on Arch Linux with CachyOS kernel. For power users.",
		},
		{
			ID: "flounder-gnome", Name: "Flounder", Emoji: "🐡",
			Base: "Debian 13 Trixie", Desktop: "gnome", DesktopName: "GNOME",
			ImageRef:    "ghcr.io/tuna-os/flounder:gnome",
			Description: "Rock-solid GNOME on Debian Stable.",
		},
	}

	// Override with C:\wootc\images.json if present
	custom := filepath.Join(wootcDir(), "images.json")
	if data, err := os.ReadFile(custom); err == nil {
		var override []Image
		if json.Unmarshal(data, &override) == nil && len(override) > 0 {
			return override, nil
		}
	}

	return catalog, nil
}

// ── System information ────────────────────────────────────────────────────────

// GetSystemInfo inspects the host for BitLocker, Fast Startup, UEFI, etc.
// On non-Windows (dev mode) it returns safe stub values.
func (a *App) GetSystemInfo() SystemInfo {
	return getSystemInfo()
}

// ── Install ───────────────────────────────────────────────────────────────────

// StartInstall begins the install pipeline in a goroutine. Progress events
// are emitted via Wails runtime events (event: "install:progress").
// Returns immediately — poll GetStatus() or listen to events.
func (a *App) StartInstall(cfg InstallConfig) error {
	if a.status.Running {
		return fmt.Errorf("install already in progress")
	}

	ctx, cancel := context.WithCancel(a.ctx)
	a.cancel = cancel
	a.status = InstallStatus{Running: true}

	go func() {
		err := a.runInstall(ctx, cfg)
		a.status.Running = false
		if err != nil && err != context.Canceled {
			a.status.Error = err.Error()
			a.emit(ProgressEvent{
				Step: "error", Message: err.Error(), Percent: 0, Error: err.Error(),
			})
		} else if err == nil {
			a.status.Done = true
			a.emit(ProgressEvent{
				Step: "done", Message: "Installation complete. Reboot to start TunaOS.", Percent: 100, Done: true,
			})
		}
	}()

	return nil
}

// CancelInstall aborts a running install. Partially-written files are cleaned up
// by runInstall's deferred cleanup.
func (a *App) CancelInstall() {
	if a.cancel != nil {
		a.cancel()
	}
}

// GetStatus returns current install state.
func (a *App) GetStatus() InstallStatus {
	return a.status
}

// Reboot triggers an immediate Windows reboot (requires admin).
func (a *App) Reboot() error {
	return rebootWindows()
}

// ── Existing install detection ────────────────────────────────────────────────

func (a *App) existingInstallFound() bool {
	disk := filepath.Join(wootcDir(), "disks", "root.vhdx")
	_, err := os.Stat(disk)
	return err == nil
}

// ExistingInstallFound is the JS-callable version.
func (a *App) ExistingInstallFound() bool {
	return a.existingInstallFound()
}

// ── Uninstall ─────────────────────────────────────────────────────────────────

// Uninstall removes the BCD entry and C:\wootc\ (except root.vhdx which the
// user must delete separately to avoid accidental data loss).
func (a *App) Uninstall() error {
	return uninstall(a.ctx)
}

// ── Internal install pipeline ─────────────────────────────────────────────────

func (a *App) runInstall(ctx context.Context, cfg InstallConfig) error {
	steps := []struct {
		name    string
		percent float64
		fn      func() error
	}{
		{"Checking system", 2, func() error { return checkSystem() }},
		{"Disabling Fast Startup", 5, func() error { return disableFastStartup() }},
		{"Creating directories", 8, func() error { return createDirectories() }},
		{"Creating root.vhdx", 15, func() error { return createRootDisk(cfg.DiskSizeGB) }},
		{"Downloading deployer", 50, func() error {
			return downloadDeployer(ctx, func(p float64) {
				a.emit(ProgressEvent{
					Step:    "Downloading deployer",
					Message: fmt.Sprintf("Downloading deployer kernel + initramfs… %.0f%%", p*35),
					Percent: 15 + p*35,
				})
			})
		}},
		{"Writing GRUB config", 55, func() error { return writeGrubConfig(cfg) }},
		{"Setting up ESP", 65, func() error { return setupESP(cfg.Bootloader) }},
		{"Configuring BCD", 80, func() error { return configureBCD(cfg.Bootloader) }},
		{"Writing vault.json", 85, func() error { return writeVault(cfg) }},
		{"Finalizing", 95, func() error {
			// Small deliberate pause so the user sees "done"
			time.Sleep(500 * time.Millisecond)
			return nil
		}},
	}

	for _, s := range steps {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		a.emit(ProgressEvent{Step: s.name, Message: s.name + "…", Percent: s.percent})
		if err := s.fn(); err != nil {
			return fmt.Errorf("%s: %w", s.name, err)
		}
	}
	return nil
}

// emit sends a progress event to the frontend.
func (a *App) emit(e ProgressEvent) {
	runtime.EventsEmit(a.ctx, "install:progress", e)
}

// ── Helpers ───────────────────────────────────────────────────────────────────
// wootcDir is defined per-platform in installer_windows.go / installer_other.go
