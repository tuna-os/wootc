package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
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
	// Status gates what a release channel offers (docs/RELEASING.md):
	//   "green"        — proven end-to-end by the E2E matrix; offered in every channel
	//   "experimental" — builds/works but not yet E2E-green; hidden in alpha
	// Empty is treated as "experimental" (fail safe — never surface an
	// unproven image to an alpha user by omission).
	Status string `json:"status"`
	// MokEnroll is the MokManager password for images whose custom kernel
	// needs the distribution's MOK key enrolled under Secure Boot (#248).
	// Non-empty means: the deployer queues the enrollment, and the GUI warns
	// the user about the one-time blue MokManager screen with this password.
	MokEnroll string `json:"mokEnroll,omitempty"`
}

// InstallConfig is the parameters collected on Screen 1.
type InstallConfig struct {
	ImageRef   string `json:"imageRef"`
	DiskSizeGB int    `json:"diskSizeGB"`
	Username   string `json:"username"`
	Password   string `json:"password"`
	Hostname   string `json:"hostname"`
	// Bootloader is the deployer boot chain: "auto" (default; the deployer
	// probes the image and picks the backend), "grub2" or "systemd-boot"
	// (explicit Advanced overrides).
	Bootloader string `json:"bootloader"` // "auto" | "grub2" | "systemd-boot"
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
	// WindowsLook opts into Windows-Style Mode (SPEC §4.4): bring the user's
	// wallpaper, accent, keyboard layout, taskbar pins and desktop shortcuts
	// over on first login. Default false — we honor the image maker's desktop
	// defaults unless the user asks to make it feel like Windows.
	WindowsLook bool `json:"windowsLook"`
	// SessionConsent is opt-in per app because it authorizes moving auth
	// material. An absent or false entry never stages a session envelope.
	SessionConsent map[string]bool `json:"sessionConsent,omitempty"`
	// FaultInject injects a simulated failure or cancellation at a specific
	// install boundary (root-disk|image-pull|efi-staging|bcd-arming|pre-reboot).
	FaultInject string `json:"faultInject,omitempty"`
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

	// ── Preflight safety gates (#63) ──────────────────────────────────────
	// Conditions under which starting a migration risks the user's data or
	// leaves the machine half-converted. Each is reported separately so the
	// GUI can name the ONE thing standing in the way rather than a generic
	// "cannot install".
	//
	// OnBattery: a migration interrupted by a flat battery mid-shrink is the
	// worst possible moment to lose power.
	OnBattery bool `json:"onBattery"`
	// BatteryKnown is false on desktops and where the query failed; only an
	// affirmative "running on battery" should ever block.
	BatteryKnown bool `json:"batteryKnown"`
	// PendingReboot: a servicing operation can rewrite boot configuration
	// underneath us, or resume in the middle of the migration. Narrow by
	// design — see pendingReboot() for why PendingFileRenameOperations is
	// deliberately NOT one of the signals.
	PendingReboot bool `json:"pendingReboot"`
	// PendingRebootReason names the signal that fired ("servicing",
	// "windows-update"), so a refusal can be argued with rather than guessed at.
	PendingRebootReason string `json:"pendingRebootReason"`
	// Hibernated: hiberfil.sys present means the NTFS in-memory state is
	// newer than the disk. Mounting that read-write from Linux is exactly
	// how NTFS gets corrupted — the data loss wootc exists to prevent.
	Hibernated bool `json:"hibernated"`
	// RAMGB and Is64Bit gate hardware that cannot run the result.
	RAMGB   float64 `json:"ramGB"`
	Is64Bit bool    `json:"is64Bit"`
	// DataPartitions lists unencrypted fixed volumes (other than C:) that
	// could hold root.disk when C: is BitLocker-protected.
	DataPartitions []DataPartition `json:"dataPartitions"`
	// BitLockerRecoveryKeyWarning is true when BitLocker ProtectionStatus is
	// On and the user should record their recovery key before proceeding (#63).
	// This is honest disclosure, independent of whether we unlock C: (#61).
	BitLockerRecoveryKeyWarning bool `json:"bitLockerRecoveryKeyWarning"`
	// SuggestedHostname is this Windows machine's name, sanitised into a
	// legal Linux hostname, so the migrated system keeps the identity the
	// user already knows instead of a generic default (#174). Empty when the
	// name could not be read or sanitises to nothing; the GUI then falls back
	// to its own default rather than showing a blank field.
	SuggestedHostname string `json:"suggestedHostname"`
	// SuggestedUsername is the signed-in Windows account name, sanitised into
	// a legal Linux username, so the migrated system keeps the identity the
	// user already has. Empty when unreadable or when nothing usable
	// survives; the GUI then leaves the field for the user to fill.
	SuggestedUsername string `json:"suggestedUsername"`
}

// sanitizeUsername converts a Windows account name into a legal Linux
// username: lowercase, [a-z0-9_-], must start with a letter or underscore,
// max 32 characters (useradd's limit).
//
// Windows account names routinely contain spaces and capitals ("James
// Reilly"), and may be a full DOMAIN\User or an email-style AzureAD name, so
// this strips any prefix before the last separator first. Returns "" when
// nothing usable survives.
func sanitizeUsername(name string) string {
	name = strings.TrimSpace(name)
	// DOMAIN\user or MicrosoftAccount\user@example.com -> the account part.
	if i := strings.LastIndexAny(name, `\/`); i >= 0 {
		name = name[i+1:]
	}
	// AzureAD/MSA names are email-shaped; the local part is the useful half.
	if i := strings.Index(name, "@"); i > 0 {
		name = name[:i]
	}

	var b strings.Builder
	for _, r := range strings.ToLower(name) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '_':
			b.WriteRune(r)
		case r == '-' || r == ' ' || r == '.':
			// Separators collapse to a single hyphen, never leading.
			if b.Len() > 0 && !strings.HasSuffix(b.String(), "-") {
				b.WriteRune('-')
			}
		}
	}
	out := strings.Trim(b.String(), "-")

	// Must not start with a digit or hyphen (useradd rejects both).
	out = strings.TrimLeft(out, "0123456789-")
	if len(out) > 32 {
		out = strings.Trim(out[:32], "-")
	}
	return out
}

// sanitizeHostname converts a Windows computer name into a legal Linux
// hostname (RFC 1123 label): lowercase, [a-z0-9-] only, no leading or
// trailing hyphen, max 63 characters.
//
// Windows names are more permissive than Linux hostnames — they allow
// underscores and other characters that systemd-hostnamed and many tools
// reject — so this cannot be a straight copy. Returns "" when nothing usable
// survives, which the caller treats as "no suggestion".
func sanitizeHostname(name string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(strings.TrimSpace(name)) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == '-' || r == '_' || r == ' ' || r == '.':
			// Collapse separators to a single hyphen; never start with one.
			if b.Len() > 0 && !strings.HasSuffix(b.String(), "-") {
				b.WriteRune('-')
			}
		}
	}
	out := strings.Trim(b.String(), "-")
	if len(out) > 63 {
		out = strings.Trim(out[:63], "-")
	}
	return out
}

// suggestUsername and suggestHostname wrap the sanitisers with the fallbacks
// the bare-minimum launchpad contract requires: identity must ALWAYS derive,
// because a derived identity is what keeps those fields under Advanced and
// the default form down to a single password prompt. A Windows account named
// entirely in non-Latin script (routine on non-English Windows, #197) would
// otherwise sanitise to "" and turn back into a question.
func suggestUsername(raw string) string {
	if s := sanitizeUsername(raw); s != "" {
		return s
	}
	return "winuser"
}

func suggestHostname(raw string) string {
	if s := sanitizeHostname(raw); s != "" {
		return s
	}
	// Fall back to the distribution's own name so a Bazzite install never
	// boots calling itself "tunaos".
	if b := sanitizeHostname(effectiveBranding().Name); b != "" {
		return b
	}
	return "tunaos"
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

// SupportPolicy is what the current release channel allows. The frontend
// reads it to gate the UI to green-only scenarios (docs/RELEASING.md); the
// backend enforces the same rules in StartInstall (defense in depth).
type SupportPolicy struct {
	Channel            string `json:"channel"`            // alpha | beta | stable
	ExperimentalImages bool   `json:"experimentalImages"` // offer non-green images?
	BitLockerSupported bool   `json:"bitlockerSupported"` // is the FDE path green yet? (#34)
	CustomImageAllowed bool   `json:"customImageAllowed"` // arbitrary OCI ref?
	Reason             string `json:"reason"`             // one-liner for the UI
}

// supportChannel resolves the active release channel. Default is the
// conservative "alpha"; overridable for testing via C:\wootc\channel.txt or
// $WOOTC_CHANNEL.
func supportChannel() string {
	if c := os.Getenv("WOOTC_CHANNEL"); c != "" {
		return c
	}
	if data, err := os.ReadFile(filepath.Join(wootcDir(), "channel.txt")); err == nil {
		if c := strings.TrimSpace(string(data)); c != "" {
			return c
		}
	}
	return "alpha"
}

// GetSupportPolicy returns the gating policy for the active channel.
func (a *App) GetSupportPolicy() SupportPolicy {
	var pol SupportPolicy
	switch supportChannel() {
	case "beta":
		// Full matrix green (the beta bar): everything is on the table; the
		// axes that are still red stay explicitly false until their issue closes.
		pol = SupportPolicy{Channel: "beta", ExperimentalImages: true,
			BitLockerSupported: false, CustomImageAllowed: true,
			Reason: "Beta — most images and scenarios supported."}
	case "stable":
		pol = SupportPolicy{Channel: "stable", ExperimentalImages: true,
			BitLockerSupported: true, CustomImageAllowed: true,
			Reason: ""}
	default: // alpha
		pol = SupportPolicy{Channel: "alpha", ExperimentalImages: false,
			BitLockerSupported: false, CustomImageAllowed: false,
			Reason: "Alpha — only fully-tested images and unencrypted disks are offered. More unlock as testing goes green."}
	}
	// A branded installer installs its own distribution: no custom OCI ref,
	// on any channel. This is the backend side of the brand's
	// hideCustomImage — the frontend hiding the field is not enforcement.
	if effectiveBranding().HideCustomImage {
		pol.CustomImageAllowed = false
	}
	// The E2E harness exists precisely to test images BEFORE they are green;
	// in drive mode the channel gate must not hide them, or a directive for
	// an experimental image finds no card and the run silently installs the
	// default instead (run 32581422435: "bazzite" installed bluefin-lts —
	// the drive loop now also refuses on mismatch, this is the enabling
	// half). Real users never run with this environment variable set.
	if os.Getenv("WOOTC_E2E_DRIVE") == "1" {
		pol.ExperimentalImages = true
	}
	return pol
}

// gateScenario refuses an install the active channel has not proven green.
func (a *App) gateScenario(cfg InstallConfig) error {
	pol := a.GetSupportPolicy()
	// BitLocker/FDE path is not green yet (#34).
	if !pol.BitLockerSupported {
		si := getSystemInfo()
		if si.BitLockerOn {
			return fmt.Errorf("BitLocker drive encryption isn't supported in the %s yet — "+
				"we're finishing testing so your files stay safe. It's coming soon; "+
				"for now, wootc works on PCs where drive encryption is off", pol.Channel)
		}
	}
	// Only offer images the channel permits. Enterprise images.json override
	// (custom refs) is trusted; a custom ref typed by the user is gated.
	if !pol.ExperimentalImages {
		imgs, _ := a.GetImages()
		ok := false
		for _, img := range imgs {
			if img.ImageRef == cfg.ImageRef {
				ok = true
				break
			}
		}
		if !ok && !pol.CustomImageAllowed {
			return fmt.Errorf("this image isn't in the tested set for the %s yet. "+
				"Please pick one of the offered images — more become available as testing goes green", pol.Channel)
		}
	}
	return nil
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
	// Name is the distribution being installed ("TunaOS", "Bazzite") — what
	// the screens, the boot menu, and Add/Remove Programs call the result.
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
	// ProductName is the installer's own name (window title, title bar,
	// "run <product> again" copy). The generic build is "wootc"; branded
	// builds never surface that word (docs/branding-and-distribution.md).
	ProductName string `json:"productName"`
	// ExeName names the release asset ("Bazzite-Installer" → .exe). Consumed
	// by the release workflow, carried here so one file defines a brand.
	ExeName string `json:"exeName"`
	// Catalog restricts the offered images to these ids from images.json, in
	// this order. Empty = the full (channel-gated) catalog.
	Catalog []string `json:"catalog"`
	// DefaultImage pre-selects a catalog entry on the launchpad.
	DefaultImage string `json:"defaultImage"`
	// HideCustomImage removes the custom-OCI field regardless of channel:
	// a branded installer installs its own distribution, nothing else.
	HideCustomImage bool `json:"hideCustomImage"`
	// PreloadImage asks the app to download the OCI image on Windows so the
	// deployer never needs the network (laptops have no Wi-Fi in the
	// initramfs — docs/branding-and-distribution.md §3).
	PreloadImage bool `json:"preloadImage"`
	// Real brand assets (deep branding). LogoDataURI replaces the emoji
	// wherever a mark renders; FontDataURI + FontFamily bring the brand's
	// actual typeface (embedded, never fetched); ThemeCSS is injected after
	// style.css and restyles tokens and components (buttons, radii, palette).
	// Populated from the embedded brand directory; an enterprise overlay may
	// supply logoDataUri inline in brand.json and CSS via C:\wootc\brand.css.
	FontFamily  string `json:"fontFamily"`
	LogoDataURI string `json:"logoDataUri"`
	FontDataURI string `json:"fontDataUri"`
	ThemeCSS    string `json:"themeCss"`
}

// GetBranding returns the effective branding. The frontend calls this on
// startup and keeps it in state.brand.
func (a *App) GetBranding() Branding {
	return effectiveBranding()
}

// mergeBranding overlays non-empty fields of over onto base.
// ── Install ───────────────────────────────────────────────────────────────────

// normalizeBootloader validates the requested boot chain and fills in the
// default. "auto" is the contract the GUI and `headless -bootloader` both
// send: the deployer probes the image and picks the backend, which is what
// took dakota/composefs green. "grub2" and "systemd-boot" are explicit
// Advanced overrides. Anything else is a caller bug, not a user choice.
func normalizeBootloader(v string) (string, error) {
	switch v {
	case "":
		return "auto", nil
	case "auto", "grub2", "systemd-boot":
		return v, nil
	default:
		return "", fmt.Errorf("unsupported bootloader %q", v)
	}
}

// StartInstall begins the install pipeline in a goroutine. Progress events
// are emitted via Wails runtime events (event: "install:progress").
// Returns immediately — poll GetStatus() or listen to events.
func (a *App) StartInstall(cfg InstallConfig) error {
	// Green-gate (docs/RELEASING.md): refuse scenarios the active channel has
	// not proven, so an alpha user can never be walked into a known-red path.
	// The frontend gates the UI too; this is the authoritative backstop.
	if err := a.gateScenario(cfg); err != nil {
		return err
	}
	bootloader, err := normalizeBootloader(cfg.Bootloader)
	if err != nil {
		return err
	}
	cfg.Bootloader = bootloader
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

// ── E2E drive mode ────────────────────────────────────────────────────────────
// The GUI E2E cannot reach the WebView over CDP: wails always passes its own
// AdditionalBrowserArguments, which makes BOTH WebView2 loaders ignore
// WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS (proven live, runs 20260723T1044/1115).
// Instead the harness drives the real UI through the same Go<->JS bridge every
// user interaction crosses: it writes a directive file, the frontend executes
// it as DOM events against the live form, and reports state back here. Inert
// unless WOOTC_E2E_DRIVE=1 is set in the app's environment.

func e2eDrivePath(name string) string {
	// filepath.Separator, not runtime.GOOS: "runtime" is the wails runtime here.
	if filepath.Separator == '\\' {
		return `C:\wootc\` + name
	}
	return "/tmp/wootc-" + name
}

// E2EDriveDirective returns the pending drive directive, or "" when drive
// mode is off or no directive exists.
func (a *App) E2EDriveDirective() string {
	if os.Getenv("WOOTC_E2E_DRIVE") != "1" {
		return ""
	}
	b, err := os.ReadFile(e2eDrivePath("e2e-drive.json"))
	if err != nil {
		return ""
	}
	return string(b)
}

// E2EDriveReport persists the frontend's current state for the harness.
func (a *App) E2EDriveReport(state string) {
	if os.Getenv("WOOTC_E2E_DRIVE") != "1" {
		return
	}
	_ = os.WriteFile(e2eDrivePath("e2e-drive-state.json"), []byte(state), 0o644)
}

// ── Existing install detection ────────────────────────────────────────────────

func (a *App) existingInstallFound() bool {
	return getUninstallInfo().Found
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
	// Orphaned: no root.disk anywhere, but leftover boot arming (bcd-guid /
	// state.json) exists — the "user deleted the folder by hand" case, which
	// previously had NO GUI path to clean up the boot entry.
	Orphaned bool `json:"orphaned"`
	// Deployed: the deployer has completed at least once (its staged journal
	// exists, or the lifecycle state says deployed/healthy) — so this PC has
	// a bootable TunaOS and the control panel can offer to restart into it.
	Deployed bool `json:"deployed"`
}

// BootIntoLinux arms ONE more one-shot boot of the existing wootc entry and
// restarts. Same mechanism as the install's arming: bootsequence only, so
// Windows remains the default. This is the Windows-side half of closing the
// post-deploy loop (North Star audit): even when the deployer could not
// re-arm itself, the user has a button that actually starts their Linux.
func (a *App) BootIntoLinux() error {
	if err := armOneShotFromPersistedGUID(); err != nil {
		return err
	}
	return rebootWindows()
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
		{"Checking your PC", 2, func() error { return checkSystem() }},
		{"Preparing Windows", 5, func() error { return disableFastStartup() }},
		{"Setting things up", 8, func() error { return createDirectories() }},
		// Resolve where the user's files ACTUALLY live while Windows is still
		// running and can read its own registry (#64). Best-effort: on a machine
		// with no redirection nothing is lost if this fails, and the Phase-2
		// bridge falls back to the literal profile layout.
		{"Finding your files", 9, func() error { recordKnownFolders(); return nil }},
		{"Making room for Linux", 15, func() error { return createRootDisk(cfg.DiskSizeGB) }},
		{"Downloading Linux", 50, func() error {
			return downloadDeployer(ctx, func(p float64) {
				emit(ProgressEvent{
					Step:    "Downloading Linux",
					Message: fmt.Sprintf("Downloading Linux… %.0f%%", p*35),
					Percent: 15 + p*35,
				})
			})
		}},
		{"Downloading your Linux system", 54, func() error {
			// Offline-first (docs/branding-and-distribution.md §3): pull the
			// selected image to C:\wootc\bundle\oci while the user's working
			// Windows network still exists — the deployer initramfs has no
			// Wi-Fi and must not need one. On for every brand that sets
			// preloadImage (all branded builds); the generic build can opt in
			// with WOOTC_PRELOAD=1 until the offline matrix axis proves it
			// everywhere. Failing here is fatal ON PURPOSE: this machine's
			// network already failed while Windows could still say so —
			// discovering that after the reboot would strand the user at a
			// splash screen instead of an error they can act on.
			// WOOTC_PRELOAD=0 force-disables even for branded builds: the
			// E2E harness runs BRANDED exes (the walkthrough videos must
			// show the installer users actually get) but the offline bundle
			// path has its own matrix axis (#217) — until that is green,
			// the harness proves branding and deploy separately from
			// preload. Real users never run with this variable set.
			if os.Getenv("WOOTC_PRELOAD") == "0" {
				return nil
			}
			if !effectiveBranding().PreloadImage && os.Getenv("WOOTC_PRELOAD") == "" {
				return nil
			}
			return stageImageBundle(ctx, cfg.ImageRef, func(done, total int64) {
				pct := 50.0
				msg := "Downloading your Linux system…"
				if total > 0 {
					pct = 50 + 4*float64(done)/float64(total)
					msg = fmt.Sprintf("Downloading your Linux system… %.1f of %.1f GB",
						float64(done)/1e9, float64(total)/1e9)
				}
				emit(ProgressEvent{Step: "Downloading your Linux system", Message: msg, Percent: pct})
			})
		}},
		{"Preparing the startup menu", 55, func() error { return writeGrubConfig(cfg) }},
		{"Getting Linux prepared", 65, func() error { return setupESP(cfg) }},
		{"Making Linux bootable on your machine", 80, func() error { return configureBCD(cfg.Bootloader) }},
		{"Saving your settings", 85, func() error { return writeVault(cfg) }},
		{"Saving your BitLocker recovery key", 87, func() error {
			// When C: is BitLocker-protected, capture the numerical recovery
			// password so Phase 2 (Linux) can unlock C: and the User Data
			// Bridge can find the user profiles that live there (#61).
			// This is a best-effort step: if the key cannot be extracted
			// the install still proceeds, but the bridge will report that
			// profiles are on an encrypted volume and could not be reached.
			key := captureBitLockerRecoveryKey("C:")
			if key != "" {
				if err := writeBitLockerKey(key); err != nil {
					fmt.Fprintf(os.Stderr, "[wootc] warning: could not store BitLocker recovery key: %v\n", err)
				}
			}
			return nil
		}},
		{"Looking at your installed apps", 82, func() error {
			// Registry-based program inventory (§4.3): enumerate HKLM/HKCU
			// uninstall keys before Windows goes away, so the migration
			// dashboard can show the complete picture — not just apps with
			// an AppData footprint. Best-effort: never fail install.
			if err := collectPrograms(); err != nil {
				fmt.Fprintf(os.Stderr, "[wootc] program collection skipped: %v\n", err)
			}
			return nil
		}},
		{"Checking your signed-in apps", 90, func() error {
			candidates, err := collectSessions()
			if err != nil {
				fmt.Fprintf(os.Stderr, "[wootc] session collection skipped: %v\n", err)
				return nil
			}
			results := exportConsentedSessions(candidates, cfg.SessionConsent, cfg.Password)
			for _, result := range results {
				if result.State == "failed" {
					fmt.Fprintf(os.Stderr, "[wootc] %s session export failed: %s\n", result.App, result.Reason)
				}
			}
			// This is deliberately a status ledger, not a success marker. The
			// target-side importer must replace "staged" with "imported" before
			// any UI can describe the app as signed in.
			path := filepath.Join(wootcDir(), "install", "slurp", "session", "exports.json")
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				fmt.Fprintf(os.Stderr, "[wootc] session export ledger directory skipped: %v\n", err)
				return nil
			}
			if err := os.WriteFile(path, []byte(sessionExportSummary(results)), 0o600); err != nil {
				fmt.Fprintf(os.Stderr, "[wootc] session export ledger skipped: %v\n", err)
			}
			return nil
		}},
		{"Looking for your cloud drives", 88, func() error {
			// Cloud-storage detection (#66): OneDrive, Google Drive and
			// Dropbox. Google Drive lives at a virtual drive letter (G:)
			// produced by DriveFS at runtime — from Linux, reading the
			// physical disk, it does not exist. The manifest tells the
			// Phase-2 bridge which rclone remotes to provision.
			// Best-effort: never fail install.
			recordCloudDrives()
			return nil
		}},
		{"Collecting your look and Wi-Fi", 92, func() error {
			// Wi-Fi profiles (§4.6) migrate UNCONDITIONALLY: recreated as
			// NetworkManager connections on first boot, so the user is online
			// without re-typing a single password — the friendliest thing a
			// migration can do, and safe. This used to hide inside the
			// WindowsLook gate below, which the GUI additionally never sent
			// (the field was dropped from StartInstall's payload), so no real
			// install ever brought Wi-Fi along. Best-effort: never fail the
			// install over either collection.
			if err := collectWifi(); err != nil {
				fmt.Fprintf(os.Stderr, "[wootc] wifi export skipped: %v\n", err)
			}
			// Windows-Style Mode (SPEC §4.4) is on by default and opt-out in
			// the GUI. When declined we collect nothing and the deployed
			// system keeps the image maker's desktop defaults — no slurp data
			// means apply-look no-ops on first login.
			if cfg.WindowsLook {
				if err := collectLook(); err != nil {
					fmt.Fprintf(os.Stderr, "[wootc] look collection skipped: %v\n", err)
				}
			}
			return nil
		}},
		{"Finishing up", 96, func() error {
			// Discoverability: an Add/Remove Programs entry so "how do I
			// remove this?" has the answer Windows users actually look for
			// (best-effort, removed again by uninstall).
			registerUninstallEntry()
			// Small deliberate pause so the user sees "done"
			time.Sleep(500 * time.Millisecond)
			return nil
		}},
	}

	fault := cfg.FaultInject
	if fault == "" {
		fault = os.Getenv("WOOTC_FAULT_INJECT")
	}

	// Track whether the one-shot boot entry is armed. From "Making Linux
	// bootable on your machine" (configureBCD) onward, a failure or a
	// cancel must DISARM it — otherwise a user who changed their mind, or
	// hit an error at 85%, still gets a surprise Linux boot attempt on the
	// next restart, while the UI is telling them "nothing permanent
	// changes" (North Star audit 2026-08-22).
	armed := false
	for _, s := range steps {
		select {
		case <-ctx.Done():
			if armed {
				disarmOneShot()
			}
			writeState(StateStaged, "cancelled", "")
			return ctx.Err()
		default:
		}
		emit(ProgressEvent{Step: s.name, Message: s.name + "…", Percent: s.percent})

		if fault != "" {
			switch {
			case fault == "root-disk" && s.name == "Making room for Linux":
				if armed {
					disarmOneShot()
				}
				writeState(StateFailed, s.name, "fault-injection: simulated failure during root disk creation")
				return fmt.Errorf("%s: fault-injection: simulated failure during root disk creation", s.name)
			case (fault == "image-pull" || fault == "image-download") && (s.name == "Downloading Linux" || s.name == "Downloading your Linux system"):
				if armed {
					disarmOneShot()
				}
				writeState(StateFailed, s.name, "fault-injection: simulated failure during image download")
				return fmt.Errorf("%s: fault-injection: simulated failure during image download", s.name)
			case (fault == "efi-staging" || fault == "efi") && s.name == "Getting Linux prepared":
				if armed {
					disarmOneShot()
				}
				writeState(StateFailed, s.name, "fault-injection: simulated failure during EFI staging")
				return fmt.Errorf("%s: fault-injection: simulated failure during EFI staging", s.name)
			case (fault == "bcd-arming" || fault == "bcd") && s.name == "Making Linux bootable on your machine":
				if armed {
					disarmOneShot()
				}
				writeState(StateFailed, s.name, "fault-injection: simulated failure during BCD arming")
				return fmt.Errorf("%s: fault-injection: simulated failure during BCD arming", s.name)
			}
		}

		if err := s.fn(); err != nil {
			if armed {
				disarmOneShot()
			}
			writeState(StateFailed, s.name, err.Error())
			return fmt.Errorf("%s: %w", s.name, err)
		}
		if s.name == "Making Linux bootable on your machine" {
			armed = true
		}
	}

	if fault == "pre-reboot" {
		if armed {
			disarmOneShot()
		}
		writeState(StateStaged, "cancelled", "fault-injection: simulated cancellation before reboot")
		return fmt.Errorf("fault-injection: simulated cancellation before reboot")
	}

	writeState(StateArmed, "", "")
	return nil
}

// GetLastRun returns the persisted lifecycle state so the UI can be honest
// on relaunch: a failed attempt must greet the user as a failed attempt,
// not as "an existing TunaOS installation was found".
func (a *App) GetLastRun() LifecycleState {
	s, ok := readState()
	if !ok {
		return LifecycleState{}
	}
	return s
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
		{"Checking your PC", 5}, {"Making room for Linux", 15},
		{"Downloading Linux", 50}, {"Getting Linux prepared", 65},
		{"Making Linux bootable on your machine", 80}, {"Looking at your installed apps", 85},
		{"Collecting your look and Wi-Fi", 90},
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
