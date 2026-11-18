//go:build !windows

package main

// Non-Windows development hosts have no Windows profiles to migrate.
func listWindowsProfiles(primary string) ([]ProfileAccount, error) {
	return []ProfileAccount{}, nil
}

func checkProfileCollectionIdentity() error { return nil }
