//go:build !linux

package main

import (
	"context"
	"fmt"
)

// On Windows (and macOS dev) the app is the installer; the migration
// dashboard only exists on the installed Linux system.

func detectMode() string { return "installer" }

func emitMigrationProgress(ctx context.Context, p MigrationProgress) {}

func migrationCategories() ([]BridgeCategory, error) {
	return nil, fmt.Errorf("migration dashboard is only available on the installed Linux system")
}

func convertCategory(id string, progress func(MigrationProgress)) error {
	return fmt.Errorf("migration dashboard is only available on the installed Linux system")
}

func importBrowserData() (string, error) {
	return "", fmt.Errorf("migration dashboard is only available on the installed Linux system")
}

func appMigrations() ([]AppMigration, error) {
	return nil, fmt.Errorf("migration dashboard is only available on the installed Linux system")
}

func setSessionConsent(string, bool) error {
	return fmt.Errorf("session consent is only available on the installed Linux system")
}

func reinstallApps() error {
	return fmt.Errorf("app reinstall is only available on the installed Linux system")
}

func migrationProfile() (MigrationProfile, error) {
	return MigrationProfile{}, fmt.Errorf("profile mapping is only available on the installed Linux system")
}

func setMigrationProfile(string) error {
	return fmt.Errorf("profile mapping is only available on the installed Linux system")
}

func lookMigration() (LookMigration, error) {
	return LookMigration{}, fmt.Errorf("look migration is only available on the installed Linux system")
}

func officeMigration() (OfficeMigration, error) {
	return OfficeMigration{}, fmt.Errorf("migration dashboard is only available on the installed Linux system")
}

func importSelectedSession(context.Context, SessionImportRequest) (SessionImportResult, error) {
	return SessionImportResult{}, fmt.Errorf("session import is only available in the installed Linux user's desktop")
}
