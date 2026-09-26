package main

// This file owns the stable Go-to-frontend installation contract. Keep field
// names and JSON tags backward compatible: Wails generates JavaScript bindings
// from these types.

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
	Bootloader string `json:"bootloader"`
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
