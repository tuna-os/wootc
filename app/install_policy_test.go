package main

import (
	"context"
	"errors"
	"reflect"
	"testing"
)

func TestInstallPolicyValidatesWithoutAppOrWindows(t *testing.T) {
	var calls []string
	accounts := []ProfileAccount{{WindowsDir: "Alice", LinuxUser: "alice"}}
	policy := installPolicy{
		support:    SupportPolicy{ExperimentalImages: true, BitLockerSupported: true},
		systemInfo: func() SystemInfo { calls = append(calls, "system"); return SystemInfo{} },
		checkPlatform: func(cfg InstallConfig) error {
			calls = append(calls, "platform")
			if cfg.Bootloader != "auto" || cfg.Encryption != "none" {
				t.Fatalf("unnormalized platform input: %+v", cfg)
			}
			return nil
		},
		checkSpace: func(context.Context, InstallConfig) error { calls = append(calls, "space"); return nil },
		profiles: func(primary string, edits []ProfileAccount) ([]ProfileAccount, error) {
			calls = append(calls, "profiles")
			if primary != "alice" || edits != nil {
				t.Fatalf("unexpected profile input: %s %+v", primary, edits)
			}
			return accounts, nil
		},
	}
	config, err := policy.validate(context.Background(), InstallConfig{Username: "alice"})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(config.ProfileAccounts, accounts) || !reflect.DeepEqual(calls, []string{"system", "platform", "space", "profiles"}) {
		t.Fatalf("validation = %+v, calls = %v", config, calls)
	}
}

func TestInstallPolicyStopsAtRefusedPlatformBeforeSpaceOrProfiles(t *testing.T) {
	refused := errors.New("host safety gate")
	policy := installPolicy{
		support:       SupportPolicy{ExperimentalImages: true, BitLockerSupported: true},
		systemInfo:    func() SystemInfo { return SystemInfo{} },
		checkPlatform: func(InstallConfig) error { return refused },
		checkSpace:    func(context.Context, InstallConfig) error { t.Fatal("space queried after refusal"); return nil },
		profiles: func(string, []ProfileAccount) ([]ProfileAccount, error) {
			t.Fatal("profiles queried after refusal")
			return nil, nil
		},
	}
	_, err := policy.validate(context.Background(), InstallConfig{})
	if !errors.Is(err, refused) {
		t.Fatalf("validation error = %v", err)
	}
}
