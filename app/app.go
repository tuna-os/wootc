package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
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
	Bootloader  string `json:"bootloader"` // grub2 | systemd-boot
	ComposeFS   bool   `json:"composeFs"`
	Family      string `json:"family"` // el10 | fedora | arch | debian | custom
}

// InstallConfig is the parameters collected on Screen 1.
type InstallConfig struct {
	ImageRef   string `json:"imageRef"`
	DiskSizeGB int    `json:"diskSizeGB"`
	Username   string `json:"username"`
	Password   string `json:"password"`
	Hostname   string `json:"hostname"`
	Bootloader string `json:"bootloader"` // "grub2" | "systemd-boot"
	ComposeFS  bool   `json:"composeFs"`
	// StorageDrive is the drive letter (no colon) where root.disk + vault
	// live. Empty means C:. On a BitLocker-protected C:, the GUI sets this
	// to an unencrypted data volume so the deployer can mount it read-write
	// every boot without a decryption prompt (SPEC §3.5). C: stays encrypted.
	StorageDrive string `json:"storageDrive"`
	// Encryption for the Linux root inside root.disk (SPEC §2.6):
	// "none" | "tpm2-luks" (auto-unlock via TPM, recommended) |
	// "luks-passphrase" (prompt every boot).
	Encryption     string `json:"encryption"`
	LuksPassphrase string `json:"luksPassphrase"`
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
	OSVersion   string  `json:"osVersion"`
	FreeDiskGB  float64 `json:"freeDiskGB"`
	TotalDiskGB float64 `json:"totalDiskGB"`
	BitLockerOn bool    `json:"bitLockerOn"`
	// BitLockerState is the detailed C: encryption state (SPEC §3.5):
	// "off" | "on" | "encrypting" | "decrypting". "encrypting" is a hard
	// block; "on" offers the data-partition path.
	BitLockerState  string `json:"bitLockerState"`
	FastStartupOn   bool   `json:"fastStartupOn"`
	IsUEFI          bool   `json:"isUefi"`
	SecureBootOn    bool   `json:"secureBootOn"`
	SecureBootKnown bool   `json:"secureBootKnown"`
	// DefragRecommended is advisory only. Fragmentation affects VHDX
	// performance on rotating media, not correctness (SPEC §3.6).
	DefragRecommended bool `json:"defragRecommended"`
	// DataPartitions lists unencrypted fixed volumes (other than C:) that
	// could hold root.disk when C: is BitLocker-protected.
	DataPartitions []DataPartition `json:"dataPartitions"`
}

// DataPartition is a candidate unencrypted volume for root.disk.
type DataPartition struct {
	Letter    string  `json:"letter"`
	Label     string  `json:"label"`
	FreeGB    float64 `json:"freeGB"`
	Encrypted bool    `json:"encrypted"`
}

// ── App struct ────────────────────────────────────────────────────────────────

// App is the Wails application backend. All exported methods are callable
// from the frontend via the generated wailsjs bindings.
type App struct {
	ctx context.Context
	// mu guards status and cancel. GetStatus() is polled from the frontend
	// on a timer while the install goroutine mutates status concurrently —
	// without the lock that is a data race the Go race detector flags.
	mu     sync.Mutex
	status InstallStatus
	cancel context.CancelFunc
}

func NewApp() *App {
	return &App{}
}

// setStatus atomically replaces the install status.
func (a *App) setStatus(s InstallStatus) {
	a.mu.Lock()
	a.status = s
	a.mu.Unlock()
}

// mutateStatus applies fn to the status under the lock.
func (a *App) mutateStatus(fn func(s *InstallStatus)) {
	a.mu.Lock()
	fn(&a.status)
	a.mu.Unlock()
}

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	// Check for existing install on startup — routes to Control Panel screen.
	existing := a.existingInstallFound()
	a.mutateStatus(func(s *InstallStatus) { s.Existing = existing })
}

// previewMode reports whether the app is running as a UI test harness:
// real WebView2 and real Go↔JS bindings, but destructive pipeline steps
// are stubbed so Playwright-over-CDP can exercise the GUI on a CI runner
// without touching BCD, disks, or the ESP. Set WOOTC_UI_PREVIEW=1.
func previewMode() bool { return os.Getenv("WOOTC_UI_PREVIEW") == "1" }

func (a *App) shutdown(ctx context.Context) {
	a.mu.Lock()
	cancel := a.cancel
	a.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

// ── Catalog ───────────────────────────────────────────────────────────────────

// GetImages returns the flat list of installable images from the embedded
// catalog. If C:\wootc\images.json exists it takes precedence (custom
// deployments / enterprise override).
func (a *App) GetImages() ([]Image, error) {
	// C:\wootc\images.json (custom/enterprise override) takes precedence over
	// the embedded built-in catalog.
	custom := filepath.Join(wootcDir(), "images.json")
	if data, err := os.ReadFile(custom); err == nil {
		var override []Image
		if json.Unmarshal(data, &override) == nil && len(override) > 0 {
			return override, nil
		}
	}

	var catalog []Image
	if err := json.Unmarshal(catalogJSON, &catalog); err != nil {
		return nil, fmt.Errorf("parse embedded catalog: %w", err)
	}
	return catalog, nil
}

// ── System information ────────────────────────────────────────────────────────

// GetSystemInfo inspects the host for BitLocker, Fast Startup, UEFI, etc.
// On non-Windows (dev mode) it returns safe stub values.
func (a *App) GetSystemInfo() SystemInfo {
	return getSystemInfo()
}

// ── Branding ──────────────────────────────────────────────────────────────────

// Branding lets partners ship a re-skinned migrator: product name,
// tagline, logo emoji, and a color palette applied as CSS variables at
// runtime. The frontend calls GetBranding() on startup.
type Branding struct {
	Name       string `json:"name"`
	Tagline    string `json:"tagline"`
	LogoEmoji  string `json:"logoEmoji"`
	Version    string `json:"version"`
	Accent     string `json:"accent"`     // primary action / highlight
	AccentText string `json:"accentText"` // text on accent (contrast)
	Background string `json:"background"`
	Card       string `json:"card"`
	Text       string `json:"text"`
	// InstallVerb personalizes CTA copy ("Install", "Migrate", "Switch").
	InstallVerb string `json:"installVerb"`
}

func defaultBranding() Branding {
	return Branding{
		Name: "wootc", Tagline: "Bring Windows to Linux — keep everything.",
		LogoEmoji: "🐠", Version: "0.1.0",
		Accent: "#5b6ee1", AccentText: "#ffffff",
		Background: "#0a0a0f", Card: "#13131e", Text: "#e8e8f0",
		InstallVerb: "Install",
	}
}

// GetBranding returns the effective branding: the built-in default,
// overlaid by C:\wootc\brand.json when present (enterprise / partner
// re-skin). Unknown or empty fields fall back to the default.
func (a *App) GetBranding() Branding {
	b := defaultBranding()
	custom := filepath.Join(wootcDir(), "brand.json")
	if data, err := os.ReadFile(custom); err == nil {
		var over Branding
		if json.Unmarshal(data, &over) == nil {
			mergeBranding(&b, over)
		}
	}
	return b
}

// mergeBranding overlays non-empty fields of over onto base.
func mergeBranding(base *Branding, over Branding) {
	set := func(dst *string, v string) {
		if v != "" {
			*dst = v
		}
	}
	set(&base.Name, over.Name)
	set(&base.Tagline, over.Tagline)
	set(&base.LogoEmoji, over.LogoEmoji)
	set(&base.Version, over.Version)
	set(&base.Accent, over.Accent)
	set(&base.AccentText, over.AccentText)
	set(&base.Background, over.Background)
	set(&base.Card, over.Card)
	set(&base.Text, over.Text)
	set(&base.InstallVerb, over.InstallVerb)
}

// ── Install ───────────────────────────────────────────────────────────────────

// StartInstall begins the install pipeline in a goroutine. Progress events
// are emitted via Wails runtime events (event: "install:progress").
// Returns immediately — poll GetStatus() or listen to events.
func (a *App) StartInstall(cfg InstallConfig) error {
	if cfg.Bootloader == "" {
		cfg.Bootloader = "grub2"
	}
	if cfg.Bootloader != "grub2" && cfg.Bootloader != "systemd-boot" {
		return fmt.Errorf("unsupported bootloader %q", cfg.Bootloader)
	}
	if cfg.Encryption == "" {
		cfg.Encryption = "tpm2-luks"
	}
	switch cfg.Encryption {
	case "none", "tpm2-luks":
	case "luks-passphrase":
		if cfg.LuksPassphrase == "" {
			return fmt.Errorf("a LUKS passphrase is required for passphrase encryption")
		}
	default:
		return fmt.Errorf("unsupported Linux disk encryption mode %q", cfg.Encryption)
	}
	if err := validatePlatformConfig(cfg); err != nil {
		return err
	}

	ctx, cancel := context.WithCancel(a.ctx)

	// Atomically claim the install slot: reject a concurrent StartInstall
	// rather than spawn a second pipeline against the same disk. Preserve
	// Existing so the Control Panel routing survives a re-install.
	a.mu.Lock()
	if a.status.Running {
		a.mu.Unlock()
		cancel()
		return fmt.Errorf("install already in progress")
	}
	a.status = InstallStatus{Running: true, Existing: a.status.Existing}
	a.cancel = cancel
	a.mu.Unlock()

	// Preview mode: emit a scripted progress run so the GUI's progress and
	// done screens can be driven under CDP without a real install.
	if previewMode() {
		go a.runPreviewInstall(ctx)
		return nil
	}

	go func() {
		err := a.runInstall(ctx, cfg)
		// Always clear Running, including the cancellation path, so a cancelled
		// install does not leave the GUI stuck on the progress screen.
		a.mutateStatus(func(s *InstallStatus) {
			s.Running = false
			if err != nil && err != context.Canceled {
				s.Error = err.Error()
			} else if err == nil {
				s.Done = true
			}
		})
		if err != nil && err != context.Canceled {
			a.emit(ProgressEvent{
				Step: "error", Message: err.Error(), Percent: 0, Error: err.Error(),
			})
		} else if err == nil {
			a.emit(ProgressEvent{
				Step: "done", Message: "Installation complete. Reboot to start TunaOS.", Percent: 100, Done: true,
			})
		}
	}()

	return nil
}

// DefragDrive performs the optional NTFS optimization offered by the
// launchpad preflight. It is never run automatically.
func (a *App) DefragDrive() error { return defragDrive() }

// CancelInstall aborts a running install. Partially-written files are cleaned up
// by runInstall's deferred cleanup.
func (a *App) CancelInstall() {
	a.mu.Lock()
	cancel := a.cancel
	a.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

// GetStatus returns current install state.
func (a *App) GetStatus() InstallStatus {
	a.mu.Lock()
	defer a.mu.Unlock()
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

// UninstallInfo describes an existing install so the uninstaller can offer
// the right options (SPEC §5): where root.disk lives and whether that
// volume was created by wootc (and is therefore safe to remove entirely).
type UninstallInfo struct {
	Found          bool    `json:"found"`
	StorageDrive   string  `json:"storageDrive"` // where root.disk lives
	DiskPath       string  `json:"diskPath"`     // full path to root.disk
	DiskSizeGB     float64 `json:"diskSizeGB"`
	OnDedicatedVol bool    `json:"onDedicatedVol"` // wootc-created data partition
	ReclaimGB      float64 `json:"reclaimGB"`      // space freed if the volume is removed
}

// GetUninstallInfo inspects the machine for an existing wootc install.
func (a *App) GetUninstallInfo() UninstallInfo {
	return getUninstallInfo()
}

// UninstallOptions controls how much the uninstaller removes (SPEC §5).
type UninstallOptions struct {
	DeleteRootDisk  bool `json:"deleteRootDisk"`  // delete root.disk (loses Linux data)
	RemovePartition bool `json:"removePartition"` // remove the wootc data partition, extend C:
}

// UninstallWith performs a configurable uninstall.
func (a *App) UninstallWith(opts UninstallOptions) error {
	return uninstallWith(a.ctx, opts)
}

// ── Internal install pipeline ─────────────────────────────────────────────────

func (a *App) runInstall(ctx context.Context, cfg InstallConfig) error {
	return runPipeline(ctx, cfg, a.emit)
}

// runPipeline executes the install steps, reporting progress through emit.
// It is shared between the GUI (Wails events) and headless mode (stdout),
// so E2E can exercise the exact production pipeline without a display.
func runPipeline(ctx context.Context, cfg InstallConfig, emit func(ProgressEvent)) error {
	// Direct root.disk + vault to the chosen (possibly unencrypted) volume.
	setStorageDrive(cfg.StorageDrive)
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
				emit(ProgressEvent{
					Step:    "Downloading deployer",
					Message: fmt.Sprintf("Downloading deployer kernel + initramfs… %.0f%%", p*35),
					Percent: 15 + p*35,
				})
			})
		}},
		{"Writing GRUB config", 55, func() error { return writeGrubConfig(cfg) }},
		{"Setting up ESP", 65, func() error { return setupESP(cfg) }},
		{"Configuring BCD", 80, func() error { return configureBCD(cfg.Bootloader) }},
		{"Writing vault.json", 85, func() error { return writeVault(cfg) }},
		{"Collecting your look", 90, func() error {
			// Best-effort: never fail the install over wallpaper slurping.
			if err := collectLook(); err != nil {
				fmt.Fprintf(os.Stderr, "[wootc] look collection skipped: %v\n", err)
			}
			return nil
		}},
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
		emit(ProgressEvent{Step: s.name, Message: s.name + "…", Percent: s.percent})
		if err := s.fn(); err != nil {
			writeState(StateFailed, s.name, err.Error())
			return fmt.Errorf("%s: %w", s.name, err)
		}
	}
	writeState(StateArmed, "", "")
	return nil
}

// emit sends a progress event to the frontend.
func (a *App) emit(e ProgressEvent) {
	runtime.EventsEmit(a.ctx, "install:progress", e)
}

// runPreviewInstall scripts a fast, harmless progress run for UI testing.
func (a *App) runPreviewInstall(ctx context.Context) {
	steps := []struct {
		name    string
		percent float64
	}{
		{"Checking system", 5}, {"Creating root.vhdx", 15},
		{"Downloading deployer", 50}, {"Setting up ESP", 65},
		{"Configuring BCD", 80}, {"Collecting your look", 90},
	}
	for _, s := range steps {
		select {
		case <-ctx.Done():
			a.mutateStatus(func(s *InstallStatus) { s.Running = false })
			return
		case <-time.After(300 * time.Millisecond):
		}
		a.emit(ProgressEvent{Step: s.name, Message: s.name + "…", Percent: s.percent})
	}
	a.mutateStatus(func(s *InstallStatus) {
		s.Running = false
		s.Done = true
	})
	a.emit(ProgressEvent{Step: "done", Message: "Installation complete (preview).", Percent: 100, Done: true})
}

// ── Helpers ───────────────────────────────────────────────────────────────────
// wootcDir is defined per-platform in installer_windows.go / installer_other.go
