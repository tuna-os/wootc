package main

import (
	"fmt"
	"strings"
)

// ── Deployer boot menus ─────────────────────────────────────────────────────
// The GRUB menu the deployer boots from shows for five seconds on every
// install, so its titles are user-facing text: a Bazzite user must read
// "Install Bazzite (automatic)", not a word nothing ever told them.
//
// Only the TITLE is branded. Nothing finds these menus by title: GRUB picks
// the entry by index (set default=0), the ESP ownership guards match the
// "# wootc" comment marker (esp_ownership.go wootcGrubOwnership), and
// cleanup removes the files by path (esp_cleanup.go). The marker, the
// paths, the kernel arguments and the systemd-boot entry FILE name stay —
// they are the on-disk contract shared with the deployer, recovery and
// uninstall, and an install made by an older version must stay findable.
// boot_menu_test.go pins both halves.

// bootMenuLabel is the distribution name the deployer menus show. The
// generic build keeps "wootc" (the same titles setup-wootc.ps1 writes);
// a branded build shows its distribution, made safe for a GRUB
// double-quoted string and a systemd-boot title line.
func bootMenuLabel(b Branding) string {
	if b.ProductName == "" || strings.EqualFold(b.ProductName, "wootc") {
		return "wootc"
	}
	if label := bootMenuSafe(b.Name); label != "" {
		return label
	}
	if label := bootMenuSafe(b.ProductName); label != "" {
		return label
	}
	return "Linux"
}

// bootMenuSafe keeps only characters that mean nothing to GRUB's parser
// inside "…" (no $ expansion, no \ escapes, no quote, no newline, no
// braces or semicolons) and that the firmware console can draw: ASCII
// letters, digits, space and . _ + ( ) -. Runs of spaces collapse, and the
// result is capped so a long name cannot push the menu off a narrow screen.
func bootMenuSafe(name string) string {
	var b strings.Builder
	for _, r := range name {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9',
			r == ' ', r == '.', r == '_', r == '+', r == '(', r == ')', r == '-':
			b.WriteRune(r)
		default:
			b.WriteRune(' ')
		}
	}
	out := strings.Join(strings.Fields(b.String()), " ")
	if len(out) > 40 {
		out = strings.TrimSpace(out[:40])
	}
	return out
}

// deployerGrubMenu is the one-shot installer menu staged on the ESP for the
// signed GRUB (EFI\fedora, EFI\redhat, EFI\wootc grub.cfg). args is the
// shared tail of the kernel command line (LUKS, boot stack, E2E console).
func deployerGrubMenu(label, imageRef, hostname, args string) string {
	return fmt.Sprintf(`%s - one-shot Linux installation
set default=0
set timeout=5

menuentry "Install %s (automatic)" {
    linux /EFI/wootc/deployer-vmlinuz wootc.image=%s wootc.hostname=%s wootc.vault=/wootc/install/vault.json%s quiet
    initrd /EFI/wootc/deployer-initramfs.img
}

menuentry "Install %s (debug)" {
    linux /EFI/wootc/deployer-vmlinuz wootc.image=%s wootc.hostname=%s wootc.vault=/wootc/install/vault.json%s wootc.debug
    initrd /EFI/wootc/deployer-initramfs.img
}
`, wootcGrubMarker, label, imageRef, hostname, args, label, imageRef, hostname, args)
}

// deployerInstallMenu is install\grub.install.cfg, the first-boot menu kept
// beside the deployer files on the Windows drive.
func deployerInstallMenu(label, imageRef, hostname string) string {
	return fmt.Sprintf(`# wootc first-boot installer menu
set default=0
set timeout=5

menuentry "Install %s (automatic)" {
    linux /wootc/install/deployer-vmlinuz wootc.image=%s wootc.hostname=%s wootc.vault=/wootc/install/vault.json quiet
    initrd /wootc/install/deployer-initramfs.img
}

menuentry "Install %s (debug)" {
    linux /wootc/install/deployer-vmlinuz wootc.image=%s wootc.hostname=%s wootc.vault=/wootc/install/vault.json wootc.debug
    initrd /wootc/install/deployer-initramfs.img
}
`, label, imageRef, hostname, label, imageRef, hostname)
}

// deployerLoaderEntry is loader\entries\wootc-deployer.conf for
// systemd-boot images. The file name is the contract (loader.conf names it
// as default, esp_cleanup.go removes it by path); only the title is branded.
func deployerLoaderEntry(label, imageRef, hostname, args string) string {
	return fmt.Sprintf("title %s installer\nlinux /EFI/wootc/deployer-vmlinuz\ninitrd /EFI/wootc/deployer-initramfs.img\noptions wootc.image=%s wootc.hostname=%s wootc.vault=/wootc/install/vault.json wootc.bootloader=systemd%s quiet\n",
		label, imageRef, hostname, args)
}

// embeddedProductName is the product name compiled into this exe, ignoring
// any runtime overlay — for messages about the state directory the overlay
// lives in, when that directory is the thing not to be trusted.
func embeddedProductName() string {
	if b, ok := embeddedBranding(); ok && b.ProductName != "" {
		return b.ProductName
	}
	return "wootc"
}
