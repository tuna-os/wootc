package main

import "fmt"

// ProfileAccountPlan is the observed secondary-profile mapping shown for review.
// The directory is an observed basename, not a caller-supplied filesystem path.
type ProfileAccountPlan struct {
	Accounts []ProfileAccount `json:"accounts"`
	Warnings []string         `json:"warnings"`
}

// GetProfileAccountPlan discovers defaults without writing a vault or changing
// accounts. StartInstall independently revalidates the complete edited mapping.
func (a *App) GetProfileAccountPlan(primary string) (ProfileAccountPlan, error) {
	if primary == "" || sanitizeUsername(primary) != primary || reservedProfileAccount(primary) {
		return ProfileAccountPlan{}, fmt.Errorf("choose a valid non-system primary Linux account before reviewing the profile plan")
	}
	if err := checkProfileCollectionIdentity(); err != nil {
		return ProfileAccountPlan{}, err
	}
	accounts, err := resolveProfileAccounts(primary, nil)
	if err != nil {
		return ProfileAccountPlan{}, err
	}
	return ProfileAccountPlan{
		Accounts: append([]ProfileAccount{}, accounts...),
		Warnings: append([]string{}, profileAccountWarnings(accounts)...),
	}, nil
}
