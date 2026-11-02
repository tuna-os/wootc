package main

// ── Migration dashboard (User Data Bridge, SPEC §4) ──────────────────────────
// The same Wails app serves two roles: on Windows it is the installer; on
// the installed Linux system it is the migration dashboard. The frontend
// picks the surface via GetMode().

// BridgeCategory is one row of the migration dashboard.
type BridgeCategory struct {
	ID          string `json:"id"`          // "Documents", "steam", "browser", ...
	Label       string `json:"label"`       // human name shown in the UI
	Description string `json:"description"` // friendly one-liner, incl. caveats
	SizeBytes   int64  `json:"sizeBytes"`   // -1 = unknown / still calculating
	State       string `json:"state"`       // bridged | native | available | unavailable
	Reversible  bool   `json:"reversible"`
}

// MigrationProgress is emitted on the "migrate:progress" event during a
// category conversion.
type MigrationProgress struct {
	Category string  `json:"category"`
	Percent  float64 `json:"percent"`
	Done     bool    `json:"done"`
	Error    string  `json:"error,omitempty"`
}

// GetMode tells the frontend which surface to render: "installer"
// (Windows, or Linux dev run) or "migration" (installed Linux system with
// the Windows host volume bridged at /host).
func (a *App) GetMode() string {
	return detectMode()
}

// GetMigrationCategories returns the dashboard rows for the current user.
func (a *App) GetMigrationCategories() ([]BridgeCategory, error) {
	return migrationCategories()
}

// ConvertCategory copies a bridged folder category to native Linux storage
// and swaps the bind mount (stage 4, reversible — Windows copy untouched).
// Progress arrives via "migrate:progress" events.
func (a *App) ConvertCategory(id string) error {
	return convertCategory(id, func(p MigrationProgress) {
		if a.ctx != nil {
			emitMigrationProgress(a.ctx, p)
		}
	})
}

// ImportBrowserData runs the browser import (stage 3) for the current user.
func (a *App) ImportBrowserData() (string, error) {
	return importBrowserData()
}

// AppMigration is one detected Windows application and the honest outcome
// of migrating it (docs/session-migration.md).
type AppMigration struct {
	App              string `json:"app"`
	Flatpak          string `json:"flatpak"`
	Session          string `json:"session"` // portable | staged | rewritten | imported | failed | signin | relink | none
	Copied           bool   `json:"copied"`
	Note             string `json:"note"`
	ConsentAvailable bool   `json:"consentAvailable"`
	Consent          bool   `json:"consent"`
	Verified         bool   `json:"verified"` // true only for a verified imported result
}

// GetAppMigrations returns the per-app migration outcomes recorded by
// wootc-detect-apps (bridge-apps.json).
func (a *App) GetAppMigrations() ([]AppMigration, error) {
	return appMigrations()
}

// GetSessionCandidates reports which Windows sessions were proven
// decryptable. It never returns tokens or decrypted payloads.
func (a *App) GetSessionCandidates() ([]SessionCandidate, error) {
	return sessionCandidates()
}

// SetSessionConsent records the user's explicit per-app choice. It does not
// copy a token by itself; the Windows-online exporter consumes the same
// decision when a supported install is staged.
func (a *App) SetSessionConsent(app string, consent bool) error {
	return setSessionConsent(app, consent)
}

// ReinstallApps installs the detected Flatpak counterparts without copying
// their credentials or application data.
func (a *App) ReinstallApps() error {
	return reinstallApps()
}

type MigrationProfile struct {
	LinuxUser      string `json:"linuxUser"`
	WindowsProfile string `json:"windowsProfile"`
	Matched        bool   `json:"matched"`
	Note           string `json:"note"`
}

func (a *App) GetMigrationProfile() (MigrationProfile, error) {
	return migrationProfile()
}

func (a *App) SetMigrationProfile(profile string) error {
	return setMigrationProfile(profile)
}

type LookMigration struct {
	Available bool     `json:"available"`
	Applied   bool     `json:"applied"`
	Items     []string `json:"items"`
	Note      string   `json:"note"`
}

func (a *App) GetLookMigration() (LookMigration, error) {
	return lookMigration()
}

// OfficeMigration summarizes what moved from MS Office to LibreOffice.
type OfficeMigration struct {
	Migrated []string `json:"migrated"`
	Note     string   `json:"note"`
	Present  bool     `json:"present"`
}

// GetOfficeMigration returns the LibreOffice bridge summary
// (bridge-office.json), Present=false when no Office was found.
func (a *App) GetOfficeMigration() (OfficeMigration, error) {
	return officeMigration()
}
