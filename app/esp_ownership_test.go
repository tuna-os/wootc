package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
)

// #52: installing wootc must never make an existing Linux unbootable. These
// tests use real ESP-shaped trees, because the bug being prevented is
// "a file existed and we wrote over it" — which only a filesystem can show.

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// A real Fedora owns EFI\fedora\shimx64.efi. Its grub.cfg may live elsewhere,
// so the old marker-on-grub.cfg check would pass and we would clobber a signed
// bootloader belonging to another OS.
func TestForeignShimBlocksInstall(t *testing.T) {
	esp := t.TempDir()
	writeFile(t, filepath.Join(esp, "EFI", "fedora", "shimx64.efi"), "real fedora shim")

	err := guardESPDestinations(esp, []string{filepath.Join("EFI", "fedora", "shimx64.efi")})
	if err == nil {
		t.Fatal("expected a refusal: EFI/fedora/shimx64.efi belongs to another OS")
	}
	// The message has to name the file — "installation failed" tells a user
	// nothing about what is on their disk.
	if !contains(err.Error(), "shimx64.efi") {
		t.Errorf("refusal must name the offending file, got: %v", err)
	}
}

// A wootc reinstall must not be blocked by its own previous files.
func TestOwnFilesAllowReinstall(t *testing.T) {
	esp := t.TempDir()
	rels := []string{
		filepath.Join("EFI", "fedora", "shimx64.efi"),
		filepath.Join("EFI", "wootc", "deployer-vmlinuz"),
	}
	for _, r := range rels {
		writeFile(t, filepath.Join(esp, r), "wootc-written")
	}
	if err := recordESPOwnership(esp, rels); err != nil {
		t.Fatal(err)
	}
	if err := guardESPDestinations(esp, rels); err != nil {
		t.Fatalf("a reinstall must proceed over wootc's own files, got: %v", err)
	}
}

// Claiming our files must not claim a neighbour's. This is the "preserve
// unrelated vendor directories byte-for-byte" criterion.
func TestOwnershipDoesNotClaimNeighbours(t *testing.T) {
	esp := t.TempDir()
	ours := filepath.Join("EFI", "fedora", "shimx64.efi")
	theirs := filepath.Join("EFI", "ubuntu", "shimx64.efi")
	writeFile(t, filepath.Join(esp, ours), "wootc")
	writeFile(t, filepath.Join(esp, theirs), "ubuntu's bootloader")

	if err := recordESPOwnership(esp, []string{ours}); err != nil {
		t.Fatal(err)
	}
	if err := guardESPDestinations(esp, []string{theirs}); err == nil {
		t.Fatal("claiming our own files must not grant ownership of another vendor's")
	}
	// And their file is untouched.
	got, err := os.ReadFile(filepath.Join(esp, theirs))
	if err != nil || string(got) != "ubuntu's bootloader" {
		t.Errorf("neighbour's bootloader was modified: %q (%v)", got, err)
	}
}

// FAT32 is case-insensitive and tools disagree about separators; ownership must
// survive both or a reinstall wrongly reads as a foreign OS.
func TestOwnershipIgnoresCaseAndSeparators(t *testing.T) {
	esp := t.TempDir()
	writeFile(t, filepath.Join(esp, "EFI", "wootc", "deployer-vmlinuz"), "x")
	if err := recordESPOwnership(esp, []string{`EFI\wootc\deployer-vmlinuz`}); err != nil {
		t.Fatal(err)
	}
	if err := guardESPDestinations(esp, []string{"efi/WOOTC/deployer-vmlinuz"}); err != nil {
		t.Fatalf("ownership must be case- and separator-insensitive, got: %v", err)
	}
}

// An absent destination is the normal first install.
func TestAbsentDestinationIsFine(t *testing.T) {
	esp := t.TempDir()
	if err := guardESPDestinations(esp, []string{filepath.Join("EFI", "fedora", "shimx64.efi")}); err != nil {
		t.Fatalf("a clean ESP must install without complaint, got: %v", err)
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && (func() bool {
		for i := 0; i+len(needle) <= len(haystack); i++ {
			if haystack[i:i+len(needle)] == needle {
				return true
			}
		}
		return false
	})()
}

// wootc's OWN directory must never be treated as foreign. The first version of
// the guard refused el10-gnome-win11ent on
// "EFI\wootc\deployer-initramfs.img ... belongs to another operating system" —
// a file only wootc ever writes. That would have blocked every real user
// reinstalling over an existing wootc ESP.
func TestOwnNamespaceIsNeverForeign(t *testing.T) {
	esp := t.TempDir()
	rel := filepath.Join("EFI", "wootc", "deployer-initramfs.img")
	writeFile(t, filepath.Join(esp, rel), "from a previous wootc install")
	// Deliberately no manifest: this is the upgrade case, where the files
	// predate ownership tracking entirely.
	if err := guardESPDestinations(esp, []string{rel}); err != nil {
		t.Fatalf("EFI/wootc is wootc's own namespace and must not be guarded, got: %v", err)
	}
}

// An older wootc left its marker in grub.cfg but no manifest. That tree is
// ours, and a reinstall must not be refused.
func TestOlderWootcInstallIsRecognisedByItsMarker(t *testing.T) {
	esp := t.TempDir()
	writeFile(t, filepath.Join(esp, "EFI", "fedora", "grub.cfg"), wootcGrubMarker+"\nmenuentry ...")
	writeFile(t, filepath.Join(esp, "EFI", "fedora", "shimx64.efi"), "staged by an older wootc")
	if err := guardESPDestinations(esp, []string{filepath.Join("EFI", "fedora", "shimx64.efi")}); err != nil {
		t.Fatalf("an older wootc install must be recognised by its grub.cfg marker, got: %v", err)
	}
}

// A COMPLETED deploy leaves the deployer's Phase-2 menu in grub.cfg — a
// different header ("# wootc Phase 2 — ...") from this app's own. That ESP is
// ours, and a reinstall over it must not be refused as a foreign Linux
// (GUI-driven bluefin cell, run 31076749824: "belongs to another operating
// system" from files wootc itself wrote).
func TestPostDeployPhase2MenuIsRecognisedAsOurs(t *testing.T) {
	esp := t.TempDir()
	writeFile(t, filepath.Join(esp, "EFI", "fedora", "grub.cfg"),
		"# wootc Phase 2 — boot installed system from root.disk\nset default=0\nmenuentry \"TunaOS\" { ... }")
	writeFile(t, filepath.Join(esp, "EFI", "fedora", "grubx64.efi"), "target-signed grub staged by deploy.sh")
	if err := guardESPDestinations(esp, []string{filepath.Join("EFI", "fedora", "grubx64.efi")}); err != nil {
		t.Fatalf("a post-deploy Phase-2 ESP is wootc's own; reinstall must proceed, got: %v", err)
	}
	// The composefs variant's header too.
	writeFile(t, filepath.Join(esp, "EFI", "fedora", "grub.cfg"),
		"# wootc Phase 2 (composefs) — deployer kernel + patched UKI initrd\nmenuentry ...")
	if err := guardESPDestinations(esp, []string{filepath.Join("EFI", "fedora", "grubx64.efi")}); err != nil {
		t.Fatalf("a composefs Phase-2 ESP is wootc's own; reinstall must proceed, got: %v", err)
	}
}

// The manifest is written in one rendering (lowercase, forward slashes) and the
// guard checks paths in another (Windows' uppercase EFI\...\ backslashes). Both
// renderings of the same file must resolve to the same claim, or a reinstall
// reads its own boot files as another OS's. Pinned against a manifest written
// out byte-for-byte rather than through recordESPOwnership, so the property is
// asserted about the FILE FORMAT and not just about a round trip through one
// normaliser.
func TestManifestClaimSurvivesEitherPathRendering(t *testing.T) {
	esp := t.TempDir()
	writeFile(t, filepath.Join(esp, "EFI", "fedora", "shimx64.efi"), "staged by wootc")
	writeFile(t, espManifestPath(esp),
		"# Files on this EFI partition written by wootc.\nefi/fedora/shimx64.efi\n")

	for _, rel := range []string{
		`EFI\fedora\shimx64.efi`, // as Windows' filepath.Join renders it
		"EFI/fedora/shimx64.efi",
		"efi/fedora/shimx64.efi",
		`\EFI\FEDORA\SHIMX64.EFI`, // FAT32 is case-insensitive
	} {
		if err := guardESPDestinations(esp, []string{rel}); err != nil {
			t.Errorf("manifest-owned path rendered as %q must be recognised, got: %v", rel, err)
		}
	}
}

// ...and the same normalisation must NOT make a different file look claimed.
// A guard satisfied by simply matching loosely is no guard at all.
func TestNormalisationDoesNotClaimADifferentFile(t *testing.T) {
	esp := t.TempDir()
	writeFile(t, espManifestPath(esp), "efi/fedora/shimx64.efi\n")
	for _, foreign := range []string{
		filepath.Join("EFI", "fedora", "grubx64.efi"),  // sibling in the same dir
		filepath.Join("EFI", "ubuntu", "shimx64.efi"),  // same name, other vendor
		filepath.Join("EFI", "fedora", "shimx64.efi2"), // prefix of a claim
		filepath.Join("EFI", "BOOT", "bootx64.efi"),    // the firmware's fallback
	} {
		writeFile(t, filepath.Join(esp, foreign), "belongs to somebody else")
		if err := guardESPDestinations(esp, []string{foreign}); err == nil {
			t.Errorf("%s is not claimed by the manifest and must be refused", foreign)
		}
	}
}

// The real defect behind runs 31081727936 / 31160072559: a second installer
// looked at the ESP while the first was mid-copy. Claiming after the copies left
// wootc's own freshly written shimx64.efi unattributed for the length of a
// 140 MB copy, and the observer refused the install as another operating
// system's — while the manifest dumped seconds later listed every file.
//
// stageESPFile is the fix: claim, then write. So the observable state at ANY
// point during staging must never look foreign. The observer runs from inside
// the write, which is exactly the window that used to be fatal.
func TestStagingIsNeverObservableAsForeign(t *testing.T) {
	esp := t.TempDir()
	rel := filepath.Join("EFI", "fedora", "shimx64.efi")

	err := stageESPFile(esp, rel, func() error {
		// Mid-copy: the file exists (partially written), the install has not
		// finished. A concurrent installer — or this machine's next attempt
		// after a crash right here — must still see wootc's own file.
		writeFile(t, filepath.Join(esp, rel), "half a shim")
		if err := guardESPDestinations(esp, []string{rel}); err != nil {
			t.Errorf("a file wootc is in the middle of writing must not read as foreign, got: %v", err)
		}
		writeFile(t, filepath.Join(esp, rel), "a whole shim")
		return nil
	})
	if err != nil {
		t.Fatalf("staging failed: %v", err)
	}
	if err := guardESPDestinations(esp, []string{rel}); err != nil {
		t.Fatalf("after staging, the file is ours: %v", err)
	}
}

// An install interrupted mid-staging must not brick future installs. Before the
// ordering fix, a kill (or a power cut) between the first copy and the manifest
// write left a file on the ESP that every later attempt refused forever.
func TestInterruptedStagingLeavesTheESPReinstallable(t *testing.T) {
	esp := t.TempDir()
	rel := filepath.Join("EFI", "fedora", "grubx64.efi")

	// The copy starts, creates the file, and dies.
	stageErr := stageESPFile(esp, rel, func() error {
		writeFile(t, filepath.Join(esp, rel), "truncated grub")
		return os.ErrClosed // stand-in for the machine going away mid-copy
	})
	if stageErr == nil {
		t.Fatal("the interrupted write should have reported its failure")
	}

	// Next attempt: our own debris, so it may be replaced.
	if err := guardESPDestinations(esp, []string{rel}); err != nil {
		t.Fatalf("wootc must be able to reinstall over its own interrupted staging, got: %v", err)
	}
	// But the guard did not go soft: a neighbour dropped in the same directory
	// afterwards is still off limits.
	foreign := filepath.Join("EFI", "fedora", "shimx64.efi")
	writeFile(t, filepath.Join(esp, foreign), "real fedora shim")
	if err := guardESPDestinations(esp, []string{rel, foreign}); err == nil {
		t.Fatal("an unclaimed shimx64.efi beside our debris must still stop the install")
	}
}

// Every observed manifest must be one complete snapshot, retaining all earlier
// claims. Seed ownership first so an empty read can never pass as a first install,
// and add a new claim on each write so every iteration really replaces the file.
func TestManifestIsNeverObservablyEmpty(t *testing.T) {
	esp := t.TempDir()
	paths := []string{
		"efi/fedora/shimx64.efi",
		"efi/fedora/grubx64.efi",
		"efi/wootc/deployer-vmlinuz",
		"efi/wootc/deployer-initramfs.img",
	}
	initial := len(paths)
	if err := recordESPOwnership(esp, paths); err != nil {
		t.Fatal(err)
	}
	for i := range 200 {
		paths = append(paths, fmt.Sprintf("efi/wootc/claim-%03d", i))
	}

	done := make(chan struct{})
	var writerErr error
	go func() {
		defer close(done)
		for _, p := range paths[initial:] {
			if err := recordESPOwnership(esp, []string{p}); err != nil {
				writerErr = fmt.Errorf("claiming %s: %w", p, err)
				return
			}
		}
	}()
	// Even a fatal reader assertion must join the writer before TempDir cleanup
	// or test completion. Only this test's owning goroutine reports failures.
	defer func() {
		<-done
		if writerErr != nil {
			t.Errorf("manifest writer failed: %v", writerErr)
		}
	}()

	seen := initial
	for {
		owned, err := readESPOwnership(esp)
		if err != nil {
			t.Fatalf("manifest unreadable while being rewritten: %v", err)
		}
		if len(owned) < seen || len(owned) > len(paths) {
			t.Fatalf("ownership snapshot has %d claims; expected %d..%d", len(owned), seen, len(paths))
		}
		for i, p := range paths {
			if owned[p] != (i < len(owned)) {
				t.Fatalf("incomplete ownership snapshot with %d claims: path %s present=%v", len(owned), p, owned[p])
			}
		}
		seen = len(owned)
		select {
		case <-done:
			// The snapshot above may precede the last replacement. Read once
			// more after the writer has finished to check every claim landed.
			owned, err := readESPOwnership(esp)
			if err != nil {
				t.Fatalf("final manifest unreadable: %v", err)
			}
			if len(owned) != len(paths) {
				t.Fatalf("final manifest has %d claims, want %d", len(owned), len(paths))
			}
			for _, p := range paths {
				if !owned[p] {
					t.Fatalf("final manifest is missing %s", p)
				}
			}
			return
		default:
		}
	}
}

func TestManifestReplacementPreservesAnOpenSnapshot(t *testing.T) {
	esp := t.TempDir()
	oldContent := "# claims\nefi/fedora/shimx64.efi\n"
	newContent := oldContent + "efi/fedora/grubx64.efi\n"
	writeFile(t, espManifestPath(esp), oldContent)
	f, err := openESPManifest(espManifestPath(esp))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	if err := writeESPManifest(esp, newContent); err != nil {
		t.Fatalf("replacement with an open manifest reader: %v", err)
	}
	oldSnapshot, err := io.ReadAll(f)
	if err != nil || string(oldSnapshot) != oldContent {
		t.Fatalf("open reader lost its complete old snapshot: %q (%v)", oldSnapshot, err)
	}
	owned, err := readESPOwnership(esp)
	if err != nil {
		t.Fatal(err)
	}
	if len(owned) != 2 || !owned["efi/fedora/shimx64.efi"] || !owned["efi/fedora/grubx64.efi"] {
		t.Fatalf("new reader did not receive the complete replacement: %v", owned)
	}
	if !manifestLanded(espManifestPath(esp), newContent) {
		t.Fatal("replacement content could not be verified")
	}
}

func TestManifestReadFailureDoesNotBecomeEmptyOwnership(t *testing.T) {
	esp := t.TempDir()
	// A directory cannot supply manifest contents. This exercises open failures
	// on Windows and scanner read failures on platforms that can open directories.
	if err := os.MkdirAll(espManifestPath(esp), 0o755); err != nil {
		t.Fatal(err)
	}
	owned, err := readESPOwnership(esp)
	if err == nil || owned != nil {
		t.Fatalf("unreadable manifest returned ownership %v, error %v", owned, err)
	}
	rel := filepath.Join("EFI", "fedora", "shimx64.efi")
	if err := guardESPDestinations(esp, []string{rel}); err == nil {
		t.Fatal("destination guard accepted an unreadable ownership manifest")
	}
	called := false
	if err := stageESPFile(esp, rel, func() error {
		called = true
		return nil
	}); err == nil || called {
		t.Fatalf("staging proceeded without readable ownership: callback=%v, error=%v", called, err)
	}
	if manifestLanded(espManifestPath(esp), "") {
		t.Fatal("unreadable manifest was mistaken for landed empty content")
	}
}

// The temp file the atomic write uses must not survive as ESP litter, and it
// must never be mistaken for a claim.
func TestAtomicWriteLeavesNoTempFile(t *testing.T) {
	esp := t.TempDir()
	if err := recordESPOwnership(esp, []string{filepath.Join("EFI", "fedora", "shimx64.efi")}); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Dir(espManifestPath(esp)))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if e.Name() != filepath.Base(espManifestPath(esp)) {
			t.Errorf("unexpected file left in EFI\\wootc: %s", e.Name())
		}
	}
}

// ...but a REAL Fedora, whose grub.cfg carries no marker, still stops us.
func TestRealFedoraStillBlocksAfterTheNamespaceFix(t *testing.T) {
	esp := t.TempDir()
	writeFile(t, filepath.Join(esp, "EFI", "fedora", "grub.cfg"), "### BEGIN /etc/grub.d/10_linux ###")
	writeFile(t, filepath.Join(esp, "EFI", "fedora", "shimx64.efi"), "real fedora shim")
	if err := guardESPDestinations(esp, []string{filepath.Join("EFI", "fedora", "shimx64.efi")}); err == nil {
		t.Fatal("a real Fedora ESP must still block the install")
	}
}

// The rename can report failure after the move has in fact happened (run
// 32556250889, bluefin-lts: the ESP dump showed the manifest complete —
// containing the very claim whose rename "failed" with file-not-found).
// The verdict must therefore be the destination's CONTENT, not the return
// code. manifestLanded is that verdict.
func TestManifestLandedIsTheVerdict(t *testing.T) {
	esp := t.TempDir()
	final := espManifestPath(esp)
	if err := os.MkdirAll(filepath.Dir(final), 0o755); err != nil {
		t.Fatal(err)
	}
	content := "# Files on this EFI partition written by wootc.\nefi/fedora/shimx64.efi\n"
	if manifestLanded(final, content) {
		t.Fatal("no file yet — nothing can have landed")
	}
	writeFile(t, final, content)
	if !manifestLanded(final, content) {
		t.Fatal("the exact intended content is on disk; that IS success")
	}
	if manifestLanded(final, content+"efi/fedora/grubx64.efi\n") {
		t.Fatal("different intended content must not be mistaken for success")
	}
	// And the writer itself: a normal write must still land and verify.
	if err := writeESPManifest(esp, content); err != nil {
		t.Fatalf("writeESPManifest: %v", err)
	}
	if !manifestLanded(final, content) {
		t.Fatal("written manifest should verify against its own content")
	}
	if _, err := os.Stat(final + ".tmp"); err == nil {
		t.Fatal("tmp file left behind after a successful write")
	}
}

// The spiral that killed the v0.1.0-alpha.1 gate: once tmp vanishes, a
// rename-only retry loop is GUARANTEED file-not-found forever. persistManifest
// must recreate its move source and converge — and must recognize
// already-landed content without needing any tmp at all.
func TestPersistManifestSurvivesAVanishedTmp(t *testing.T) {
	dir := t.TempDir()
	final := filepath.Join(dir, "wootc-owned.txt")
	tmp := final + ".tmp"
	content := "# claims\nefi/fedora/shimx64.efi\n"

	// No tmp exists and final holds OLD content — exactly the post-phantom
	// state. The loop must rebuild tmp and replace final.
	writeFile(t, final, "# old claims\n")
	if err := persistManifest(tmp, final, content); err != nil {
		t.Fatalf("persistManifest with vanished tmp: %v", err)
	}
	if !manifestLanded(final, content) {
		t.Fatal("final does not hold the intended content")
	}
	if _, err := os.Stat(tmp); err == nil {
		t.Fatal("tmp left behind")
	}

	// Content already landed, no tmp anywhere: immediate success, no writes.
	if err := persistManifest(tmp, final, content); err != nil {
		t.Fatalf("persistManifest with landed content: %v", err)
	}
}
