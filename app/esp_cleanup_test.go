package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestESPCleanupPreservesForeignNeighbours(t *testing.T) {
	for _, legacy := range []bool{false, true} {
		t.Run(map[bool]string{false: "manifest", true: "legacy"}[legacy], func(t *testing.T) {
			root := t.TempDir()
			ours := []string{"EFI/fedora/shimx64.efi", "EFI/fedora/grub.cfg", "EFI/redhat/grub.cfg", "EFI/wootc/deployer-vmlinuz", "EFI/systemd/systemd-bootx64.efi", "loader/loader.conf", "loader/entries/wootc.conf"}
			foreign := []string{"EFI/fedora/foreign.efi", "EFI/redhat/foreign.efi", "EFI/wootc/foreign.efi", "EFI/systemd/foreign.efi", "loader/entries/foreign.conf", "EFI/Microsoft/Boot/bootmgfw.efi", "EFI/BOOT/bootx64.efi"}
			for _, rel := range ours {
				writeFile(t, filepath.Join(root, filepath.FromSlash(rel)), "# wootc owned")
			}
			for _, rel := range foreign {
				writeFile(t, filepath.Join(root, filepath.FromSlash(rel)), "foreign bytes "+rel)
			}
			if !legacy {
				if err := recordESPOwnership(root, ours); err != nil {
					t.Fatal(err)
				}
			}
			if err := cleanupESPOwnedFiles(root); err != nil {
				t.Fatal(err)
			}
			for _, rel := range ours {
				if _, err := os.Lstat(filepath.Join(root, filepath.FromSlash(rel))); !os.IsNotExist(err) {
					t.Fatalf("owned file remains: %s (%v)", rel, err)
				}
			}
			for _, rel := range foreign {
				data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
				if err != nil || string(data) != "foreign bytes "+rel {
					t.Fatalf("foreign file changed: %s", rel)
				}
			}
		})
	}
}

func TestESPCleanupInvalidManifestHasNoSideEffects(t *testing.T) {
	for _, rel := range []string{"../outside", "EFI/wootc/../../Microsoft/Boot/bootmgfw.efi", "/EFI/wootc/owned", `C:\EFI\wootc\owned`, `\\server\EFI\wootc\owned`, "EFI//wootc/owned", "EFI/wootc/file.", "EFI/wootc/file:stream", "EFI/Microsoft/Boot/bootmgfw.efi", "efi/wootc/owned "} {
		t.Run(rel, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "EFI", "wootc", "owned")
			writeFile(t, path, "preserve owned until validation")
			original := "efi/wootc/owned\n" + rel + "\n"
			writeFile(t, espManifestPath(root), original)
			if err := cleanupESPOwnedFiles(root); err == nil {
				t.Fatal("unsafe claim passed")
			}
			data, err := os.ReadFile(path)
			if err != nil || string(data) != "preserve owned until validation" {
				t.Fatal("deleted before full validation")
			}
			data, err = os.ReadFile(espManifestPath(root))
			if err != nil || string(data) != original {
				t.Fatal("manifest changed on refusal")
			}
		})
	}
}

func TestESPCleanupRejectsDirectoryClaims(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "EFI", "wootc", "claimed-directory", "foreign"), "foreign")
	writeFile(t, espManifestPath(root), "efi/wootc/claimed-directory\n")
	if err := cleanupESPOwnedFiles(root); err == nil {
		t.Fatal("directory claim passed")
	}
	if data, err := os.ReadFile(filepath.Join(root, "EFI", "wootc", "claimed-directory", "foreign")); err != nil || string(data) != "foreign" {
		t.Fatal("foreign descendant removed")
	}
}

func TestESPCleanupRetainsManifestOnFailureAndRetries(t *testing.T) {
	root := t.TempDir()
	rels := []string{"EFI/wootc/a", "EFI/wootc/b"}
	for _, rel := range rels {
		writeFile(t, filepath.Join(root, filepath.FromSlash(rel)), "owned")
	}
	if err := recordESPOwnership(root, rels); err != nil {
		t.Fatal(err)
	}
	original, _ := os.ReadFile(espManifestPath(root))
	calls := 0
	failure := errors.New("injected removal refusal")
	err := cleanupESPOwnedFilesWithRemove(root, func(path string) error {
		calls++
		if calls == 2 {
			return failure
		}
		return os.Remove(path)
	})
	if !errors.Is(err, failure) {
		t.Fatalf("lost deletion failure: %v", err)
	}
	after, err := os.ReadFile(espManifestPath(root))
	if err != nil || string(after) != string(original) {
		t.Fatal("lost retry evidence")
	}
	if err := cleanupESPOwnedFiles(root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(espManifestPath(root)); !os.IsNotExist(err) {
		t.Fatal("manifest remained after verified cleanup")
	}
}

func TestESPCleanupDoesNotTrustRemovalReturnCode(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "EFI", "wootc", "owned"), "owned")
	if err := recordESPOwnership(root, []string{"EFI/wootc/owned"}); err != nil {
		t.Fatal(err)
	}
	if err := cleanupESPOwnedFilesWithRemove(root, func(string) error { return nil }); err == nil {
		t.Fatal("success reported while file remains")
	}
	if _, err := os.Stat(espManifestPath(root)); err != nil {
		t.Fatal("manifest removed before observed deletion")
	}
}

func TestESPCleanupRejectsSymlinks(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	writeFile(t, filepath.Join(outside, "foreign"), "foreign")
	if err := os.MkdirAll(filepath.Join(root, "EFI", "wootc"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "EFI", "wootc", "link")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	writeFile(t, espManifestPath(root), "efi/wootc/link/foreign\n")
	if err := cleanupESPOwnedFiles(root); err == nil {
		t.Fatal("symlink path passed")
	}
	if data, err := os.ReadFile(filepath.Join(outside, "foreign")); err != nil || string(data) != "foreign" {
		t.Fatal("symlink target changed")
	}
}

func TestESPCleanupResolvesManifestCaseAndLeavesForeignOnlyStatus(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "eFi", "WoOtC", "OwNeD"), "owned")
	writeFile(t, filepath.Join(root, "eFi", "WoOtC", "FoReIgN"), "foreign")
	writeFile(t, filepath.Join(root, "eFi", "WoOtC", "WOOTC-OWNED.TXT"), "EFI\\WOOTC\\OWNED\n")
	if err := cleanupESPOwnedFiles(root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "eFi", "WoOtC", "OwNeD")); !os.IsNotExist(err) {
		t.Fatal("case variant owned file remains")
	}
	if data, err := os.ReadFile(filepath.Join(root, "eFi", "WoOtC", "FoReIgN")); err != nil || string(data) != "foreign" {
		t.Fatal("foreign neighbour changed")
	}
	owned, err := hasESPOwnedFiles(root)
	if err != nil || owned {
		t.Fatalf("foreign-only namespace treated as installed: %v %v", owned, err)
	}
}

func TestESPCleanupRejectsAmbiguousCase(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "EFI", "wootc", "a"), "first")
	writeFile(t, filepath.Join(root, "EFI", "wootc", "A"), "second")
	entries, err := os.ReadDir(filepath.Join(root, "EFI", "wootc"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Skip("filesystem is case-insensitive")
	}
	writeFile(t, espManifestPath(root), "efi/wootc/a\n")
	if err := cleanupESPOwnedFiles(root); err == nil {
		t.Fatal("ambiguous case claim passed")
	}
}

func TestESPCleanupRechecksCompletePlanBeforeRemovingManifest(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"a", "b"} {
		writeFile(t, filepath.Join(root, "EFI", "wootc", name), "owned")
	}
	if err := recordESPOwnership(root, []string{"EFI/wootc/a", "EFI/wootc/b"}); err != nil {
		t.Fatal(err)
	}
	err := cleanupESPOwnedFilesWithRemove(root, func(path string) error {
		if err := os.Remove(path); err != nil {
			return err
		}
		if filepath.Base(path) == "b" {
			return os.WriteFile(filepath.Join(root, "EFI", "wootc", "a"), []byte("recreated"), 0644)
		}
		return nil
	})
	if err == nil {
		t.Fatal("recreated claimed file was overlooked")
	}
	if _, err := os.Stat(espManifestPath(root)); err != nil {
		t.Fatal("retry plan lost despite remaining file")
	}
}
