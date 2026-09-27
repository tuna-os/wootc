package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// ESP ownership manifest (#52).
//
// wootc writes into EFI\fedora — a directory a real Fedora or RHEL install
// also owns. Checking grub.cfg for our marker was not enough: we overwrite
// shimx64.efi and grubx64.efi too, and another distro owns those binaries even
// when its grub.cfg lives somewhere the marker check never looks. Overwriting
// them makes that OS unbootable, which is the opposite of this project's
// reversibility promise.
//
// So: record every file wootc writes to the ESP, and before writing, refuse if
// a destination exists that we did not write. A reinstall recognises its own
// files and proceeds; anything foreign stops the install BEFORE the first byte
// is changed, while the machine is still exactly as the user left it.
//
// The manifest is a plain text file — one relative path per line — deliberately
// readable by a human staring at a broken ESP with a rescue disk.
//
// ORDERING IS THE WHOLE SAFETY ARGUMENT. A path is claimed BEFORE the byte that
// creates it, never after (stageESPFile), and the claim lands atomically. That
// gives one invariant, in both directions:
//
//	a wootc-written file exists on the ESP  <=>  the manifest claims it
//
// Claiming afterwards broke the left-to-right direction: between the first copy
// and the manifest write, wootc's own freshly written shimx64.efi sat on the
// ESP with nothing attributing it to wootc — and anything that read the ESP in
// that window (a second installer process, or the SAME machine's next attempt
// after a crash, a kill, or a power cut mid-copy) correctly concluded the file
// was unattributable and refused the install as "another operating system".
// GUI-driven runs 31081727936 and 31160072559 died exactly there, each naming a
// different member of the staged set: the ESP dump taken seconds after the
// refusal showed a COMPLETE manifest listing the very file just called foreign.
// On a user's machine the same window turns one interrupted install into a
// permanent refusal to ever install again.
//
// The right-to-left direction is what keeps the guard's teeth, so claims are
// written one file at a time, immediately before that file is created: the
// manifest can only ever name a destination wootc was in the act of writing,
// which is the same fixed set of paths it named before.
const espOwnershipManifest = `EFI\wootc\wootc-owned.txt`

// wootcGrubMarker identifies a grub.cfg written by wootc, so reinstalls can
// overwrite it while a real Linux distro's config is protected. Declared here
// rather than in the Windows-only installer because the ownership logic (and
// its tests) must build everywhere.
const wootcGrubMarker = "# wootc deployer"

// wootcGrubOwnership is the marker family every wootc grub.cfg writer shares.
// wootc writes EFI\fedora\grub.cfg from THREE places, each with its own
// header comment:
//   - this app:            "# wootc deployer ..."
//   - setup-wootc.ps1:     "# wootc first-boot installer menu" / "# wootc deployer - ..."
//   - deploy.sh (Phase 2): "# wootc Phase 2 — boot installed system ..." and
//     "# wootc Phase 2 (composefs) ..."
//
// Matching only the first refused wootc's own post-deploy ESP: a user who
// completed a deploy and later reinstalled got "belongs to another operating
// system" from the very files wootc wrote (GUI cell, run 31076749824). A
// genuine Fedora/RHEL grub.cfg contains no "# wootc" comment at all, so the
// family prefix keeps the guard's teeth against real dual-boot installs.
const wootcGrubOwnership = "# wootc"

func espManifestPath(espPath string) string {
	return filepath.Join(espPath, "EFI", "wootc", "wootc-owned.txt")
}

// readESPOwnership returns the set of ESP-relative paths wootc has written.
// A missing manifest is not an error: it means wootc has never installed here.
func readESPOwnership(espPath string) (map[string]bool, error) {
	return readESPOwnershipFile(espManifestPath(espPath))
}

func readESPOwnershipFile(path string) (map[string]bool, error) {
	owned := map[string]bool{}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return owned, nil
		}
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if line != sc.Text() {
			return nil, fmt.Errorf("ambiguous whitespace in ESP ownership path")
		}
		if err := validateESPRelativeFile(line); err != nil {
			return nil, err
		}
		owned[normalizeESPPath(line)] = true
	}
	return owned, sc.Err()
}

// normalizeESPPath makes comparisons independent of separator and case. ESPs
// are FAT32: case-insensitive, and written by tools that disagree about slashes.
func normalizeESPPath(p string) string {
	p = strings.ReplaceAll(p, `\`, "/")
	return strings.ToLower(strings.Trim(p, "/"))
}

// isOwnNamespace reports whether a path lives in a directory only wootc ever
// writes. EFI\wootc is ours by definition — nothing else puts files there — so
// guarding it refuses our OWN reinstalls. The first version of this guard did
// exactly that and blocked el10-gnome-win11ent on
// "EFI\wootc\deployer-initramfs.img ... belongs to another operating system",
// which would equally have blocked any real user reinstalling wootc.
//
// Only SHARED vendor directories (EFI\fedora) need ownership proof.
func isOwnNamespace(rel string) bool {
	return strings.HasPrefix(normalizeESPPath(rel), "efi/wootc/")
}

// ownsFedoraNamespace reports whether the EFI\fedora tree was staged by wootc.
// An older wootc predating the manifest still left its marker in grub.cfg, so
// this keeps upgrades working without weakening the guard against a real
// Fedora/RHEL install (whose grub.cfg has no such marker). The match is the
// shared "# wootc" marker family, NOT only this app's own header — the
// deployer rewrites this file with its Phase-2 menu on every completed
// deploy, and a reinstall must recognize that as ours too.
func ownsFedoraNamespace(espPath string) bool {
	data, err := os.ReadFile(filepath.Join(espPath, "EFI", "fedora", "grub.cfg"))
	return err == nil && strings.Contains(string(data), wootcGrubOwnership)
}

// guardESPDestinations refuses to continue if any destination already exists
// and was not written by wootc. Called BEFORE the first write.
func guardESPDestinations(espPath string, relPaths []string) error {
	owned, err := readESPOwnership(espPath)
	if err != nil {
		// An unreadable manifest means we cannot prove ownership. Refusing is
		// the safe direction: the cost of a false refusal is an error message,
		// the cost of a false proceed is someone's bootloader.
		return fmt.Errorf("cannot read the record of which EFI files belong to wootc (%w) — "+
			"refusing to overwrite boot files we cannot prove are ours", err)
	}
	fedoraIsOurs := ownsFedoraNamespace(espPath)
	for _, rel := range relPaths {
		full := filepath.Join(espPath, rel)
		if _, err := os.Stat(full); err != nil {
			continue // absent: nothing to clobber
		}
		if isOwnNamespace(rel) {
			continue // our own directory; nothing else writes there
		}
		if owned[normalizeESPPath(rel)] {
			continue // ours from a previous install: a reinstall may replace it
		}
		if fedoraIsOurs {
			continue // an older wootc staged this tree (marker in grub.cfg)
		}
		// Last chance before refusing: re-read the manifest. Our snapshot was
		// taken before this os.Stat, so it can predate a claim written by
		// another wootc in the meantime — and since every wootc claims a path
		// before creating it, a file that exists because another wootc put it
		// there is claimed by the time we can see it. Reading fresh closes that
		// window without loosening anything: a file wootc never wrote appears
		// in no manifest at any moment, so this can only ever un-refuse
		// wootc's own work.
		if fresh, ferr := readESPOwnership(espPath); ferr == nil && fresh[normalizeESPPath(rel)] {
			continue
		}
		return fmt.Errorf("this PC's EFI boot partition already contains %s, which wootc did not "+
			"put there — it belongs to another operating system. Installing would make that "+
			"system unbootable, so wootc stopped before changing anything", rel)
	}
	return nil
}

// recordESPOwnership claims the given paths, merging with anything already
// claimed. Call it immediately BEFORE writing each path (see stageESPFile): the
// claim is what makes the file attributable, so it has to exist by the time the
// file does.
func recordESPOwnership(espPath string, relPaths []string) error {
	owned, err := readESPOwnership(espPath)
	if err != nil {
		return err
	}
	for _, rel := range relPaths {
		if err := validateESPRelativeFile(rel); err != nil {
			return err
		}
		owned[normalizeESPPath(rel)] = true
	}
	if err := os.MkdirAll(filepath.Dir(espManifestPath(espPath)), 0o755); err != nil {
		return err
	}
	// Sorted, so the manifest a human (or the E2E's esp-dump) reads is stable
	// between installs instead of shuffled by Go's map order.
	claimed := make([]string, 0, len(owned))
	for p := range owned {
		claimed = append(claimed, p)
	}
	sort.Strings(claimed)
	var b strings.Builder
	b.WriteString("# Files on this EFI partition written by wootc.\n")
	b.WriteString("# wootc will replace these on reinstall and refuse to touch anything else.\n")
	for _, p := range claimed {
		b.WriteString(p + "\n")
	}
	return writeESPManifest(espPath, b.String())
}

// writeESPManifest replaces the manifest atomically and durably.
//
// os.WriteFile truncates in place, which leaves two ways to lose claims that
// have already been earned: a reader (another installer) can catch the file
// empty mid-rewrite and read zero owned paths, and an interruption during the
// rewrite can leave a truncated manifest on the ESP for good — after which
// wootc calls its own boot files another operating system's, forever. Write a
// sibling temp file, flush it to the device, then rename over: a reader sees
// either the whole old manifest or the whole new one, and an interruption at
// any point leaves one of those two on disk.
func writeESPManifest(espPath, content string) error {
	final := espManifestPath(espPath)
	return persistManifest(final+".tmp", final, content)
}

// persistManifest gets content into final via write-tmp + rename, surviving
// every way this Windows ESP has actually fought back:
//
//   - A scanner/indexer briefly holds a fresh file and the rename fails with
//     a sharing violation (run 32550338286). Retrying covers it.
//   - The rename REPORTS failure after the move in fact happened — two runs
//     (32556250889 and the v0.1.0-alpha.1 gate, both bluefin-lts) died on
//     "rename ...tmp -> wootc-owned.txt: The system cannot find the file
//     specified" while the ESP dump minutes later showed the manifest
//     complete, containing the very claim being written. So the destination's
//     CONTENT is the verdict, checked before anything else every iteration.
//   - The killer the first retry loop could not survive: once tmp is gone
//     (consumed by the phantom move, or eaten by the scanner), every further
//     rename is GUARANTEED file-not-found — the loop spun 20 times against a
//     vanished source. So each iteration recreates tmp when it is missing;
//     the loop always has a move source and always recognizes success.
//
// The first and last errors both survive into the failure message, because
// this path has now produced three distinct wrong diagnoses from single
// error codes.
func persistManifest(tmp, final, content string) error {
	var firstErr, lastErr error
	note := func(err error) {
		if firstErr == nil {
			firstErr = err
		}
		lastErr = err
	}
	for attempt := 0; attempt < 40; attempt++ {
		if attempt > 0 {
			time.Sleep(250 * time.Millisecond)
		}
		// Content on disk is success, whatever any error code claimed.
		if manifestLanded(final, content) {
			os.Remove(tmp) //nolint:errcheck — may already be gone; that's fine
			return nil
		}
		if _, err := os.Stat(tmp); err != nil {
			// tmp missing (first pass, phantom-consumed, or scanner-eaten):
			// recreate it, synced — the ESP is FAT32 on a device the
			// installer is about to reboot, and an unflushed manifest is a
			// lost manifest.
			if err := writeFileSynced(tmp, content); err != nil {
				note(fmt.Errorf("writing %s: %w", tmp, err))
				continue
			}
		}
		if err := os.Rename(tmp, final); err != nil {
			note(err)
			continue
		}
		return nil
	}
	if manifestLanded(final, content) {
		os.Remove(tmp) //nolint:errcheck
		return nil
	}
	os.Remove(tmp) //nolint:errcheck
	if firstErr != nil && firstErr.Error() != lastErr.Error() {
		return fmt.Errorf("replacing the boot-file manifest kept failing (first: %v; last: %w)", firstErr, lastErr)
	}
	return fmt.Errorf("replacing the boot-file manifest kept failing: %w", lastErr)
}

func writeFileSynced(path, content string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.WriteString(content); err != nil {
		f.Close()
		os.Remove(path) //nolint:errcheck
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(path) //nolint:errcheck
		return err
	}
	return f.Close()
}

// manifestLanded reports whether final already holds exactly the content this
// write intended — the ground truth a lying rename return code can't fake.
func manifestLanded(final, content string) bool {
	b, err := os.ReadFile(final)
	return err == nil && string(b) == content
}

// stageESPFile claims rel and then writes it, in that order, so the ESP is
// never in a state where a wootc-written file exists unattributed. write must
// be the call that actually creates the file at rel.
//
// If write fails the claim stays behind, deliberately: the write may well have
// created or truncated the file before failing, and a destination wootc has
// half-written must stay replaceable by the next attempt. The claim can only
// ever name a destination wootc was in the act of writing — never a path
// outside the fixed set the installer stages.
func stageESPFile(espPath, rel string, write func() error) error {
	if err := recordESPOwnership(espPath, []string{rel}); err != nil {
		return fmt.Errorf("recording that %s belongs to wootc: %w", rel, err)
	}
	return write()
}
