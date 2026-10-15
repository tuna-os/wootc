package main

// What a branded user still saw after #599: "Install wootc (automatic)" in
// the deployer's GRUB menu, and "wootc" in errors from the Windows-only code
// (BitLocker, UEFI, VM viewer, ESP guards, recovery, boot repair). These
// tests pin the branded text AND that nothing which finds an install
// (old or new) depends on it.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// The generic build's menus, exactly as every earlier release wrote them
// (and as tests/e2e/setup-wootc.ps1 still writes them). A generic install
// must come out byte for byte the same.
const legacyDeployerGrubMenu = `# wootc deployer - one-shot Linux installation
set default=0
set timeout=5

menuentry "Install wootc (automatic)" {
    linux /EFI/wootc/deployer-vmlinuz wootc.image=IMG wootc.hostname=HOST wootc.vault=/wootc/install/vault.json ARGS quiet
    initrd /EFI/wootc/deployer-initramfs.img
}

menuentry "Install wootc (debug)" {
    linux /EFI/wootc/deployer-vmlinuz wootc.image=IMG wootc.hostname=HOST wootc.vault=/wootc/install/vault.json ARGS wootc.debug
    initrd /EFI/wootc/deployer-initramfs.img
}
`

const legacyLoaderEntry = "title wootc installer\nlinux /EFI/wootc/deployer-vmlinuz\ninitrd /EFI/wootc/deployer-initramfs.img\noptions wootc.image=IMG wootc.hostname=HOST wootc.vault=/wootc/install/vault.json wootc.bootloader=systemd ARGS quiet\n"

func TestDeployerMenus_GenericBuildIsUnchanged(t *testing.T) {
	wearBrand(t, "wootc")
	label := bootMenuLabel(effectiveBranding())
	if label != "wootc" {
		t.Fatalf("generic build menu label = %q, want wootc", label)
	}
	if got := deployerGrubMenu(label, "IMG", "HOST", " ARGS"); got != legacyDeployerGrubMenu {
		t.Errorf("generic GRUB menu changed:\n%s", got)
	}
	if got := deployerLoaderEntry(label, "IMG", "HOST", " ARGS"); got != legacyLoaderEntry {
		t.Errorf("generic loader entry changed:\n%q", got)
	}
}

func TestDeployerMenus_BazziteBuildSaysBazzite(t *testing.T) {
	wearBrand(t, "bazzite")
	label := bootMenuLabel(effectiveBranding())
	if label != "Bazzite" {
		t.Fatalf("bazzite menu label = %q, want Bazzite", label)
	}
	for name, menu := range map[string]string{
		"ESP grub.cfg":     deployerGrubMenu(label, "ghcr.io/ublue-os/bazzite:stable", "pc", ""),
		"grub.install.cfg": deployerInstallMenu(label, "ghcr.io/ublue-os/bazzite:stable", "pc"),
	} {
		for _, want := range []string{`menuentry "Install Bazzite (automatic)" {`, `menuentry "Install Bazzite (debug)" {`} {
			if !strings.Contains(menu, want) {
				t.Errorf("%s lacks %s:\n%s", name, want, menu)
			}
		}
		if strings.Contains(menu, "Install wootc") {
			t.Errorf("%s still says Install wootc", name)
		}
	}
	if entry := deployerLoaderEntry(label, "x", "y", ""); !strings.HasPrefix(entry, "title Bazzite installer\n") {
		t.Errorf("loader entry title = %q", strings.SplitN(entry, "\n", 2)[0])
	}
}

// The other half: what finds and removes these menus is not the title. A
// menu written by an older release (legacy titles) and one written now
// (branded titles) must both carry the ownership marker the ESP guards and
// cleanup match, boot by index, and boot the same deployer paths.
func TestDeployerMenus_LookupsDoNotDependOnTheTitle(t *testing.T) {
	wearBrand(t, "bazzite")
	branded := deployerGrubMenu(bootMenuLabel(effectiveBranding()), "IMG", "HOST", " ARGS")
	for name, menu := range map[string]string{"older install": legacyDeployerGrubMenu, "branded install": branded} {
		if !strings.HasPrefix(menu, wootcGrubMarker) || !strings.Contains(menu, wootcGrubOwnership) {
			t.Errorf("%s: menu lacks the %q ownership marker the ESP guards match", name, wootcGrubOwnership)
		}
		if !strings.Contains(menu, "\nset default=0\n") {
			t.Errorf("%s: menu no longer boots by index", name)
		}
		if strings.Count(menu, "menuentry ") != 2 {
			t.Errorf("%s: %d menu entries, want 2", name, strings.Count(menu, "menuentry "))
		}
		for _, path := range []string{"linux /EFI/wootc/deployer-vmlinuz", "initrd /EFI/wootc/deployer-initramfs.img", "wootc.vault=/wootc/install/vault.json"} {
			if !strings.Contains(menu, path) {
				t.Errorf("%s: menu no longer boots %s", name, path)
			}
		}
	}
	// Strip the titles: what is left is identical, so no consumer can tell
	// the two apart except a person reading the menu.
	title := regexp.MustCompile(`menuentry "Install [^"]*\((automatic|debug)\)"`)
	if title.ReplaceAllString(branded, "T") != title.ReplaceAllString(legacyDeployerGrubMenu, "T") {
		t.Error("the branded menu differs from the legacy one beyond its titles")
	}
}

// A brand name lands inside a GRUB double-quoted string and on a
// systemd-boot title line. Anything GRUB would expand or end the string
// on must not survive.
func TestBootMenuLabel_IsSafeForGRUB(t *testing.T) {
	cases := map[string]string{
		"Bazzite":                       "Bazzite",
		`Evil" { linux /x }`:            "Evil linux x",
		"$prefix/../../x":               "prefix .. .. x",
		"Back\\slash`tick`":             "Back slash tick",
		"Two\nLines\r\n":                "Two Lines",
		"Semi;colon && more":            "Semi colon more",
		"Café Linux":                    "Caf Linux",
		strings.Repeat("Long ", 20):     "Long Long Long Long Long Long Long Long",
		"Fedora (Atomic) 42.1_x86+beta": "Fedora (Atomic) 42.1_x86+beta",
	}
	for in, want := range cases {
		if got := bootMenuSafe(in); got != want {
			t.Errorf("bootMenuSafe(%q) = %q, want %q", in, got, want)
		}
	}
	unsafe := regexp.MustCompile(`["$\\{};\n\r` + "`" + `]`)
	if got := bootMenuLabel(Branding{Name: `"$`, ProductName: `{;}`}); got == "" || unsafe.MatchString(got) {
		t.Errorf("all-unsafe brand produced label %q", got)
	}
	for id := range loadBlessings(t) {
		wearBrand(t, id)
		label := bootMenuLabel(effectiveBranding())
		if label == "" || unsafe.MatchString(label) {
			t.Errorf("brand %s: menu label %q is empty or unsafe", id, label)
		}
		if id != "wootc" && strings.Contains(strings.ToLower(label), "wootc") {
			t.Errorf("brand %s: menu label %q says wootc", id, label)
		}
	}
}

// The Windows-only messages cannot be executed on Linux, so hold the
// source: no string literal in app/*.go may carry the bare word "wootc",
// except the identifiers and markers that are the on-disk contract. A new
// user-facing sentence that hard-codes it fails here; it must go through
// productName().
func TestUserFacingStringsNeverHardcodeWootc(t *testing.T) {
	word := regexp.MustCompile(`(^|[^\\/._\-\[A-Za-z0-9#])wootc($|[^\\/._\-\]A-Za-z0-9])`)
	allowed := func(v string) bool {
		switch {
		case v == "wootc": // identifiers: brandID, firmware description, EFI\wootc segment, task names
			return true
		case v == " (wootc)", v == "wootc — Windows bootc Installer": // the generic build's documented ARP entry and window title
			return true
		case strings.HasPrefix(v, "# wootc"): // GRUB/loader ownership markers (esp_ownership.go)
			return true
		case strings.HasPrefix(v, "wootc: "): // stderr diagnostics, never shown in the window
			return true
		}
		return false
	}
	files, err := filepath.Glob("*.go")
	if err != nil || len(files) == 0 {
		t.Fatalf("no sources to scan: %v", err)
	}
	fset := token.NewFileSet()
	scanned := 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		scanned++
		ast.Inspect(file, func(n ast.Node) bool {
			lit, ok := n.(*ast.BasicLit)
			if !ok || lit.Kind != token.STRING {
				return true
			}
			v, err := strconv.Unquote(lit.Value)
			if err == nil && word.MatchString(v) && !allowed(v) {
				t.Errorf("%s: string literal hard-codes \"wootc\"; use productName(): %.120q", fset.Position(lit.Pos()), v)
			}
			return true
		})
	}
	if scanned < 50 {
		t.Fatalf("scanned only %d files; the glob no longer sees app/", scanned)
	}
}

// wearBrand makes this test binary the -X main.brandID=<id> exe, with the
// runtime overlays that would mask the embedded brand moved aside.
func wearBrand(t *testing.T, id string) {
	t.Helper()
	old := brandID
	brandID = id
	t.Cleanup(func() { brandID = old })
	for _, name := range []string{"brand.json", "brand.css"} {
		path := filepath.Join(wootcDir(), name)
		saved, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		if err := os.Remove(path); err != nil {
			t.Fatalf("clear overlay %s: %v", path, err)
		}
		t.Cleanup(func() { _ = os.WriteFile(path, saved, 0o644) })
	}
}
