//go:build windows

package main

import (
	"context"
	"fmt"
)

func (authorization *nativeInstallAuthorization) intentID() string { return authorization.intent }

func (authorization *nativeInstallAuthorization) confirmIntent(data []byte, action func(InstallConfig) error) error {
	return authorization.confirm(data, action)
}

// newWindowsNativeInstallPrepare builds the install-purpose plan check. It
// runs the same validation as StartInstall, binds the plan to a volume and an
// image the engine observed, and grants an intent only through
// prepareNativeInstallAuthorization, whose revalidation re-observes that
// volume before the plan is granted and again before it runs.
func newWindowsNativeInstallPrepare(ctx context.Context, app *App, user *nativeOriginalUser, session, brand string, observe func(context.Context) (NativeConfigurationSnapshot, error), selection func(context.Context) error) nativeInstallPrepare {
	return func(plan InstallConfig) (nativeInstallAuthority, NativeInstallGrant, error) {
		if user == nil {
			return nil, NativeInstallGrant{}, fmt.Errorf("native install preparation unavailable")
		}
		validated, err := app.validateInstallConfig(plan)
		if err != nil {
			return nil, NativeInstallGrant{}, err
		}
		readCtx, cancel := context.WithTimeout(ctx, nativeConfigurationBudget)
		snapshot, err := observe(readCtx)
		cancel()
		if err != nil {
			return nil, NativeInstallGrant{}, fmt.Errorf("the engine could not observe this computer's storage; try again")
		}
		binding, err := bindNativeInstallPlan(snapshot, validated)
		if err != nil {
			return nil, NativeInstallGrant{}, err
		}
		revalidate := func() error {
			readCtx, cancel := context.WithTimeout(ctx, nativeConfigurationBudget)
			defer cancel()
			if err := selection(readCtx); err != nil {
				return err
			}
			current, err := observe(readCtx)
			if err != nil {
				return err
			}
			return binding.unchangedIn(current, validated)
		}
		validate := func(config InstallConfig) error {
			_, err := app.validateInstallConfig(config)
			return err
		}
		authority, err := prepareNativeInstallAuthorization(user, session, brand, validated, validate, revalidate)
		if err != nil {
			return nil, NativeInstallGrant{}, err
		}
		info := getSystemInfo()
		return authority, NativeInstallGrant{
			SchemaVersion: 1, Session: session, BrandID: brand, IntentID: authority.intent,
			ImageRef: validated.ImageRef, StorageDrive: validated.StorageDrive, DiskSizeGB: validated.DiskSizeGB, Encryption: validated.Encryption,
			BitLockerOn: info.BitLockerOn, BitLockerRecoveryKeyWarning: info.BitLockerRecoveryKeyWarning,
			FastStartupOn: info.FastStartupOn, SecureBootChainWarning: info.SecureBootChainWarning,
		}, nil
	}
}
