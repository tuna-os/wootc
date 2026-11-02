package main

import (
	"context"
	"fmt"
)

// installPolicy consumes observed facts and explicit platform gates. It owns
// validation, not discovery, UI state, or privileged execution. The shell adapter
// supplies the same observations to initial and consent-time validation.
type installPolicy struct {
	support       SupportPolicy
	images        func() ([]Image, error)
	systemInfo    func() SystemInfo
	checkPlatform func(InstallConfig) error
	checkSpace    func(context.Context, InstallConfig) error
	profiles      func(string, []ProfileAccount) ([]ProfileAccount, error)
}

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

// Shared policy calculation accepts observations from the caller. It performs
// no filesystem discovery and does not authorize an operation.
func supportPolicyFor(channel string, brand Branding, driveMode bool) SupportPolicy {
	var pol SupportPolicy
	switch channel {
	case "beta":
		// Full matrix green (the beta bar): everything is on the table; the
		// axes that are still red stay explicitly false until their issue closes.
		pol = SupportPolicy{Channel: "beta", ExperimentalImages: true,
			BitLockerSupported: true, CustomImageAllowed: true,
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
	if brand.HideCustomImage {
		pol.CustomImageAllowed = false
	}
	// The E2E harness exists precisely to test images BEFORE they are green;
	// in drive mode the channel gate must not hide them, or a directive for
	// an experimental image finds no card and the run silently installs the
	// default instead (run 32581422435: "bazzite" installed bluefin-lts —
	// the drive loop now also refuses on mismatch, this is the enabling
	// half). Real users never run with this environment variable set.
	if driveMode {
		pol.ExperimentalImages = true
	}
	return pol
}

func (p installPolicy) gateScenario(cfg InstallConfig) error {
	pol := p.support
	si := p.systemInfo()
	// BitLocker/FDE path is not green yet (#34).
	if !pol.BitLockerSupported {
		if si.BitLockerOn {
			return fmt.Errorf("BitLocker drive encryption isn't supported in the %s yet — "+
				"we're finishing testing so your files stay safe. It's coming soon; "+
				"for now, %s works on PCs where drive encryption is off", pol.Channel, productName())
		}
	}
	// Secure Boot: can this firmware launch the shim we stage? (#322)
	// Checked here, before a single byte is written, because the failure it
	// prevents ("bad shim signature") happens after the reboot, where the
	// user has no way to find out why Windows came back.
	if v := secureBootChainVerdict(si); v.Blocked {
		return fmt.Errorf("%s", v.Message)
	}
	// Only offer images the channel permits. Enterprise images.json override
	// (custom refs) is trusted; a custom ref typed by the user is gated.
	if !pol.ExperimentalImages {
		imgs, err := p.images()
		if err != nil {
			return fmt.Errorf("read tested image catalogue: %w", err)
		}
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

func (p installPolicy) validate(ctx context.Context, cfg InstallConfig) (InstallConfig, error) {
	// Green-gate (docs/RELEASING.md): refuse scenarios the active channel has
	// not proven, so an alpha user can never be walked into a known-red path.
	// The frontend gates the UI too; this is the authoritative backstop.
	if err := p.gateScenario(cfg); err != nil {
		return InstallConfig{}, err
	}
	bootloader, err := normalizeBootloader(cfg.Bootloader)
	if err != nil {
		return InstallConfig{}, err
	}
	cfg.Bootloader = bootloader
	if cfg.Encryption == "" {
		cfg.Encryption = "none"
	}
	switch cfg.Encryption {
	case "none":
	case "tpm2-luks":
		// The deployer's verification step cannot open a TPM-sealed root
		// (fisherman stages TPM enrollment for first boot and only emits a
		// recovery key the deployer never captures), so every such install
		// aborts at verification, and the user is never shown the key the
		// first boot asks for (#551, #33). Refuse it until that path works.
		return InstallConfig{}, fmt.Errorf("TPM auto-unlock is not available yet: the install cannot " +
			"verify a TPM-sealed disk and would not show you its recovery key (#551). " +
			"Choose no encryption, or a passphrase")
	case "luks-passphrase":
		if cfg.LuksPassphrase == "" {
			return InstallConfig{}, fmt.Errorf("a LUKS passphrase is required for passphrase encryption")
		}
	default:
		return InstallConfig{}, fmt.Errorf("unsupported Linux disk encryption mode %q", cfg.Encryption)
	}
	if err := p.checkPlatform(cfg); err != nil {
		return InstallConfig{}, err
	}
	// root.disk AND the deployer's scratch for this image must fit on the
	// storage drive. The deployer checks too, but only after the reboot.
	if err := p.checkSpace(ctx, cfg); err != nil {
		return InstallConfig{}, err
	}
	accounts, err := p.profiles(cfg.Username, cfg.ProfileAccounts)
	if err != nil {
		return InstallConfig{}, err
	}
	cfg.ProfileAccounts = accounts
	return cfg, nil
}
