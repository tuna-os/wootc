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

func officeMigration() (OfficeMigration, error) {
	return OfficeMigration{}, fmt.Errorf("migration dashboard is only available on the installed Linux system")
}
