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
