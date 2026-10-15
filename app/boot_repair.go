package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// ── Boot repair (#290) ───────────────────────────────────────────────────────
// After a failed deploy or a recovery boot the user needs one place that
// says what the boot configuration looks like NOW, and that changes only
// what wootc provably owns. The old "Repair boot" button re-ran setupESP and
// configureBCD without looking first and printed "complete" without looking
// after — success derived from the absence of an error, which is the proxy
// bug class AGENTS.md warns about.
//
// The flow is observe → plan → act → observe again:
//
//   - observeBoot (per-OS) gathers raw evidence: bcdedit dumps, armed.json,
//     the ESP ownership manifest and the current hashes of the files it
//     names, and the lifecycle markers.
//   - planBootRepair (pure, tested here) turns that evidence into a report:
//     the boot state, which entries are wootc's, and which actions are safe.
//     Anything it cannot attribute is a refusal, never a guess.
//   - the actions re-observe and report success only when the new
//     observation shows the state they promised.

// Boot states a report can name. "unknown" is the honest answer whenever the
// firmware boot manager could not be read or parsed.
const (
	BootStateWindowsOnly  = "windows-only"   // no wootc entry in bootsequence or displayorder
	BootStateOneShotArmed = "one-shot-armed" // next boot (only) goes to the wootc entry
	BootStateWootcDefault = "wootc-default"  // a wootc entry sits in the permanent order ahead of Windows
	BootStateWootcListed  = "wootc-listed"   // Windows boots first, but a wootc entry is in the permanent order
	BootStateForeignNext  = "foreign-next"   // next boot goes to an entry wootc does not own
	BootStateUnknown      = "unknown"
)

// Ownership verdicts for the boot chain as a whole.
const (
	OwnershipCertain   = "certain"   // every wootc artifact found is attributable
	OwnershipUncertain = "uncertain" // something claims to be wootc's but cannot be proven
	OwnershipNone      = "none"      // no wootc boot artifact was observed
)

// bootRepairDescription is the firmware entry description configureBCD and
// setup-wootc.ps1 both write. Matching is exact, as in deleteWootcBCDEntries.
const bootRepairDescription = "wootc"

// windowsBootManagerID is the well-known firmware entry for Windows.
const windowsBootManagerID = "{bootmgr}"

// BootObservation is the raw evidence one inspection gathered. Fields are
// filled by observeBoot; planBootRepair does no I/O, so tests can drive
// every row of the table.
type BootObservation struct {
	ObservedAt string `json:"observedAt"`

	FirmwareEnum    string `json:"firmwareEnum,omitempty"`    // bcdedit /enum firmware
	FirmwareEnumErr string `json:"firmwareEnumErr,omitempty"` // non-empty when the dump failed

	ArmedPresent bool       `json:"armedPresent"`
	ArmedErr     string     `json:"armedErr,omitempty"`
	Armed        ArmedState `json:"armed"`
	RecordedGUID string     `json:"recordedGuid,omitempty"` // install\bcd-guid.txt

	ESPFound      bool              `json:"espFound"`
	ESPErr        string            `json:"espErr,omitempty"`
	ManifestErr   string            `json:"manifestErr,omitempty"`
	OwnedESPFiles []string          `json:"ownedEspFiles,omitempty"`
	CurrentHashes map[string]string `json:"currentHashes,omitempty"` // rel path -> sha256; "" when missing

	LifecyclePresent bool           `json:"lifecyclePresent"`
	Lifecycle        LifecycleState `json:"lifecycle"`
	DeployerStarted  bool           `json:"deployerStarted"`
}

// BootRepairReport is what the user (GUI or `recover --inspect`) sees.
type BootRepairReport struct {
	ObservedAt        string   `json:"observedAt"`
	BootState         string   `json:"bootState"`
	Ownership         string   `json:"ownership"`
	LifecycleState    string   `json:"lifecycleState,omitempty"`
	BootSequence      []string `json:"bootSequence,omitempty"`
	DisplayOrder      []string `json:"displayOrder,omitempty"`
	WootcEntries      []string `json:"wootcEntries,omitempty"`
	Findings          []string `json:"findings,omitempty"`
	Refusals          []string `json:"refusals,omitempty"`
	CanRestoreWindows bool     `json:"canRestoreWindows"`
	CanRepairBoot     bool     `json:"canRepairBoot"`
	Recommended       string   `json:"recommended"`
	BundlePath        string   `json:"bundlePath,omitempty"`
}

// Recommended actions.
const (
	BootActionNone           = "none"
	BootActionRestoreWindows = "restore-windows"
	BootActionRepairBoot     = "repair-boot"
	BootActionManual         = "manual"
)

// bcdEntry is one object from a bcdedit enumeration.
type bcdEntry struct {
	ID          string
	Description string
	Fields      map[string][]string
}

var bcdHeaderUnderline = regexp.MustCompile(`^-+$`)

// parseBCDEntries splits a bcdedit /enum dump into objects. Each object
// starts with a title line followed by a dashed underline; values that span
// several lines (displayorder, bootsequence) continue on indented lines.
func parseBCDEntries(out string) []bcdEntry {
	var entries []bcdEntry
	var cur *bcdEntry
	lastKey := ""
	lines := strings.Split(strings.ReplaceAll(out, "\r\n", "\n"), "\n")
	for i, raw := range lines {
		line := strings.TrimRight(raw, " \t")
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if bcdHeaderUnderline.MatchString(trimmed) {
			continue
		}
		if i+1 < len(lines) && bcdHeaderUnderline.MatchString(strings.TrimSpace(lines[i+1])) {
			entries = append(entries, bcdEntry{Fields: map[string][]string{}})
			cur = &entries[len(entries)-1]
			lastKey = ""
			continue
		}
		if cur == nil {
			continue
		}
		if line[0] == ' ' || line[0] == '\t' {
			if lastKey != "" {
				cur.Fields[lastKey] = append(cur.Fields[lastKey], trimmed)
			}
			continue
		}
		parts := strings.Fields(trimmed)
		key := strings.ToLower(parts[0])
		val := strings.TrimSpace(strings.TrimPrefix(trimmed, parts[0]))
		cur.Fields[key] = append(cur.Fields[key], val)
		lastKey = key
		switch key {
		case "identifier":
			cur.ID = strings.ToLower(val)
		case "description":
			cur.Description = val
		}
	}
	return entries
}

func normalizeGUID(g string) string {
	return strings.ToLower(strings.TrimSpace(g))
}

// planBootRepair is the decision table. It never reports a state it did not
// observe: an unreadable boot manager is BootStateUnknown and blocks every
// action that writes to BCD.
func planBootRepair(obs BootObservation) BootRepairReport {
	r := BootRepairReport{
		ObservedAt:     obs.ObservedAt,
		BootState:      BootStateUnknown,
		Ownership:      OwnershipNone,
		LifecycleState: obs.Lifecycle.State,
		Recommended:    BootActionManual,
	}
	// bcdUncertain blocks every BCD write; ESP doubt blocks only repair,
	// which is the one action that rewrites ESP files.
	bcdUncertain := false
	uncertain := func(format string, a ...any) {
		r.Ownership = OwnershipUncertain
		r.Refusals = append(r.Refusals, fmt.Sprintf(format, a...))
	}
	uncertainBCD := func(format string, a ...any) {
		bcdUncertain = true
		uncertain(format, a...)
	}
	find := func(format string, a ...any) {
		r.Findings = append(r.Findings, fmt.Sprintf(format, a...))
	}

	// ── Lifecycle evidence ───────────────────────────────────────────────
	if obs.ArmedErr != "" {
		uncertain("armed.json exists but cannot be read (%s); the recorded install cannot be identified", obs.ArmedErr)
	}
	if obs.LifecyclePresent {
		find("lifecycle state is %q (written by %s at %s)", obs.Lifecycle.State, obs.Lifecycle.UpdatedBy, obs.Lifecycle.UpdatedAt)
	} else {
		find("no lifecycle state (state.json) was found")
	}
	if obs.DeployerStarted {
		find("the deployer started at least once (deployer-started.json)")
	}

	// ── Firmware boot manager ────────────────────────────────────────────
	if obs.FirmwareEnumErr != "" {
		r.Refusals = append(r.Refusals, "the firmware boot configuration could not be read: "+obs.FirmwareEnumErr)
		return r
	}
	entries := parseBCDEntries(obs.FirmwareEnum)
	byID := map[string]bcdEntry{}
	var fw *bcdEntry
	for i := range entries {
		byID[entries[i].ID] = entries[i]
		if entries[i].ID == "{fwbootmgr}" {
			fw = &entries[i]
		}
	}
	if fw == nil {
		r.Refusals = append(r.Refusals, "the firmware boot manager ({fwbootmgr}) was not found in the boot configuration dump")
		return r
	}
	_, hasWindows := byID[windowsBootManagerID]
	if !hasWindows {
		r.Refusals = append(r.Refusals, "the Windows Boot Manager entry ({bootmgr}) was not found; refusing to change the boot order")
	}

	owned := map[string]bool{}
	for _, e := range entries {
		if e.Description == bootRepairDescription && e.ID != "" {
			owned[e.ID] = true
		}
	}

	// A recorded GUID that exists under another description is a collision:
	// acting on it would edit an entry someone else owns.
	for _, rec := range []struct{ name, id string }{
		{"armed.json", obs.Armed.BcdGuid},
		{"bcd-guid.txt", obs.RecordedGUID},
	} {
		id := normalizeGUID(rec.id)
		if id == "" {
			continue
		}
		e, ok := byID[id]
		switch {
		case !ok:
			find("the boot entry recorded in %s (%s) no longer exists", rec.name, id)
		case e.Description != bootRepairDescription:
			uncertainBCD("the boot entry recorded in %s (%s) is now described as %q, not %q", rec.name, id, e.Description, bootRepairDescription)
		}
	}
	if a, b := normalizeGUID(obs.Armed.BcdGuid), normalizeGUID(obs.RecordedGUID); a != "" && b != "" && a != b {
		uncertainBCD("armed.json (%s) and bcd-guid.txt (%s) record different boot entries", a, b)
	}

	for id := range owned {
		r.WootcEntries = append(r.WootcEntries, id)
	}
	sort.Strings(r.WootcEntries)
	if len(owned) > 1 {
		find("%d firmware entries are named %q; earlier attempts left duplicates", len(owned), bootRepairDescription)
	}
	if len(owned) > 0 && r.Ownership == OwnershipNone {
		r.Ownership = OwnershipCertain
	}

	for _, id := range fw.Fields["bootsequence"] {
		r.BootSequence = append(r.BootSequence, normalizeGUID(id))
	}
	for _, id := range fw.Fields["displayorder"] {
		r.DisplayOrder = append(r.DisplayOrder, normalizeGUID(id))
	}

	foreignNext := false
	for _, id := range r.BootSequence {
		if !owned[id] {
			foreignNext = true
			find("the next boot goes to %s, which wootc does not own; it is left alone", id)
		}
	}
	winIdx := indexOf(r.DisplayOrder, windowsBootManagerID)
	ownedIdx := firstOwned(r.DisplayOrder, owned)
	wootcInOrder := ownedIdx < len(r.DisplayOrder)
	wootcAhead := wootcInOrder && (winIdx < 0 || ownedIdx < winIdx)
	for _, id := range r.DisplayOrder {
		if owned[id] {
			find("wootc entry %s is in the permanent boot order", id)
		}
	}
	if wootcAhead {
		find("a wootc entry is ahead of Windows in the permanent boot order; the next normal boot would not start Windows")
	}
	if len(r.DisplayOrder) > 0 && r.DisplayOrder[0] != windowsBootManagerID && !owned[r.DisplayOrder[0]] {
		find("the first permanent boot entry is %s, not Windows; it is not wootc's and is left alone", r.DisplayOrder[0])
	}

	switch {
	case foreignNext:
		r.BootState = BootStateForeignNext
	case len(r.BootSequence) > 0:
		r.BootState = BootStateOneShotArmed
	case wootcAhead:
		r.BootState = BootStateWootcDefault
	case wootcInOrder:
		r.BootState = BootStateWootcListed
	default:
		r.BootState = BootStateWindowsOnly
	}

	// ── ESP files ────────────────────────────────────────────────────────
	espOK := true
	switch {
	case obs.ESPErr != "":
		espOK = false
		find("the EFI system partition could not be located: %s", obs.ESPErr)
	case obs.ManifestErr != "":
		espOK = false
		uncertain("the ESP ownership manifest cannot be trusted (%s); no ESP file will be rewritten", obs.ManifestErr)
	}
	if espOK && obs.ArmedPresent {
		claimed := map[string]bool{}
		for _, f := range obs.OwnedESPFiles {
			claimed[normalizeESPPath(f)] = true
		}
		for _, f := range obs.Armed.EspFiles {
			rel := normalizeESPPath(f)
			if !claimed[rel] {
				uncertain("ESP file %s was staged by the install but is no longer claimed in the ownership manifest", f)
				continue
			}
			cur := obs.CurrentHashes[f]
			want := obs.Armed.EspFileHashes[f]
			switch {
			case cur == "":
				find("ESP file %s is missing", f)
			case want != "" && cur != want:
				find("ESP file %s changed since the install armed it", f)
			}
		}
	}

	// ── Actions ──────────────────────────────────────────────────────────
	bcdTrusted := !bcdUncertain && hasWindows
	needsRestore := len(r.BootSequence) > 0 || wootcInOrder || winIdx < 0
	r.CanRestoreWindows = bcdTrusted && needsRestore && !foreignNext

	healthyOrDeployed := obs.Lifecycle.State == StateHealthy || obs.Lifecycle.State == StateDeployed
	switch {
	case !obs.ArmedPresent:
		r.Refusals = append(r.Refusals, "repair needs the install record (armed.json); without it the boot chain cannot be attributed to an install — use Remove or reinstall")
	case healthyOrDeployed:
		r.Refusals = append(r.Refusals, fmt.Sprintf("the install reached %q; re-staging the installer would overwrite the installed system's boot files", obs.Lifecycle.State))
	case !espOK:
		r.Refusals = append(r.Refusals, "repair re-stages ESP files, and the ESP cannot be verified")
	}
	r.CanRepairBoot = bcdTrusted && r.Ownership != OwnershipUncertain && !foreignNext &&
		obs.ArmedPresent && !healthyOrDeployed && espOK && obs.ArmedErr == ""

	switch {
	case r.CanRestoreWindows:
		r.Recommended = BootActionRestoreWindows
	case r.BootState == BootStateWindowsOnly && winIdx >= 0 && r.Ownership != OwnershipUncertain:
		r.Recommended = BootActionNone
	case r.CanRepairBoot:
		r.Recommended = BootActionRepairBoot
	default:
		r.Recommended = BootActionManual
	}
	return r
}

func indexOf(list []string, s string) int {
	for i, v := range list {
		if v == s {
			return i
		}
	}
	return -1
}

func firstOwned(list []string, owned map[string]bool) int {
	for i, v := range list {
		if owned[v] {
			return i
		}
	}
	return len(list)
}

// restoreWindowsCommands returns the bcdedit argument lists that put Windows
// back in charge of the boot, touching only wootc-owned entries. The
// entries themselves and the ESP files stay, so Try again still works.
func restoreWindowsCommands(r BootRepairReport) ([][]string, error) {
	if !r.CanRestoreWindows {
		return nil, fmt.Errorf("restoring a Windows-only boot is not safe here: %s", strings.Join(r.Refusals, "; "))
	}
	owned := map[string]bool{}
	for _, id := range r.WootcEntries {
		owned[id] = true
	}
	var cmds [][]string
	if len(r.BootSequence) > 0 {
		for _, id := range r.BootSequence {
			if !owned[id] {
				return nil, fmt.Errorf("next boot goes to %s, which wootc does not own", id)
			}
		}
		cmds = append(cmds, []string{"/deletevalue", "{fwbootmgr}", "bootsequence"})
	}
	for _, id := range r.DisplayOrder {
		if owned[id] {
			cmds = append(cmds, []string{"/set", "{fwbootmgr}", "displayorder", id, "/remove"})
		}
	}
	// Windows missing from the permanent order means no normal boot reaches
	// it. Put it back; never reorder entries that wootc does not own.
	if indexOf(r.DisplayOrder, windowsBootManagerID) < 0 {
		cmds = append(cmds, []string{"/set", "{fwbootmgr}", "displayorder", windowsBootManagerID, "/addfirst"})
	}
	return cmds, nil
}

// verifyWindowsOnly checks a post-action observation. Success is the
// observed state, not the absence of an error from the commands.
func verifyWindowsOnly(after BootRepairReport) error {
	if after.BootState != BootStateWindowsOnly {
		return fmt.Errorf("after the change the boot state is %q, not %q", after.BootState, BootStateWindowsOnly)
	}
	if indexOf(after.DisplayOrder, windowsBootManagerID) < 0 {
		return fmt.Errorf("after the change Windows Boot Manager is not in the boot order (%v)", after.DisplayOrder)
	}
	return nil
}

// verifyRepairArmed checks the observation taken after a repair: the next
// boot must go to exactly one wootc entry, and the files the new arm
// recorded must be on the ESP with the hashes it recorded.
func verifyRepairArmed(after BootRepairReport, obs BootObservation) error {
	if after.BootState != BootStateOneShotArmed {
		return fmt.Errorf("after repair the boot state is %q, not %q", after.BootState, BootStateOneShotArmed)
	}
	want := normalizeGUID(obs.Armed.BcdGuid)
	if len(after.BootSequence) != 1 || after.BootSequence[0] != want {
		return fmt.Errorf("after repair the next boot goes to %v, not the recorded entry %s", after.BootSequence, want)
	}
	for _, f := range obs.Armed.EspFiles {
		if w := obs.Armed.EspFileHashes[f]; w == "" || obs.CurrentHashes[f] != w {
			return fmt.Errorf("after repair ESP file %s does not match the recorded hash", f)
		}
	}
	return nil
}

// observeLocalState fills the lifecycle and install-record fields that live
// under the wootc directory. The boot-configuration and ESP fields are
// platform-specific and filled by observeBoot.
func observeLocalState(obs *BootObservation) {
	obs.ObservedAt = time.Now().UTC().Format(time.RFC3339)
	if armed, err := readArmedJSON(); err == nil {
		obs.ArmedPresent = true
		obs.Armed = armed
	} else if !os.IsNotExist(err) {
		obs.ArmedErr = err.Error()
	}
	if b, err := os.ReadFile(filepath.Join(wootcDir(), "install", "bcd-guid.txt")); err == nil {
		obs.RecordedGUID = strings.TrimSpace(string(b))
	}
	obs.Lifecycle, obs.LifecyclePresent = readState()
	_, err := os.Stat(deployerStartedPath())
	obs.DeployerStarted = err == nil
}

// observeESP fills the ESP fields from a mounted ESP root.
func observeESP(obs *BootObservation, espPath string) {
	obs.ESPFound = true
	owned, err := readESPOwnership(espPath)
	if err != nil {
		obs.ManifestErr = err.Error()
		return
	}
	for f := range owned {
		obs.OwnedESPFiles = append(obs.OwnedESPFiles, f)
	}
	sort.Strings(obs.OwnedESPFiles)
	obs.CurrentHashes = map[string]string{}
	for _, f := range obs.Armed.EspFiles {
		h, err := hashFile(filepath.Join(espPath, filepath.FromSlash(f)))
		if err != nil {
			h = ""
		}
		obs.CurrentHashes[f] = h
	}
}

// repairBundleSources are the files a repair bundle copies, relative to the
// wootc directory. Missing ones are skipped and listed in the bundle index.
var repairBundleSources = []string{
	"state.json",
	filepath.Join("install", "armed.json"),
	filepath.Join("install", "bcd-guid.txt"),
	filepath.Join("install", "deployer-started.json"),
	filepath.Join("install", "recovery-verdict.json"),
	filepath.Join("logs", "deployer-last-journal.log"),
	filepath.Join("logs", "deployer.log"),
	"deployer.log",
	"install.log",
}

// writeRepairBundle collects the evidence behind a report into a fresh
// timestamped folder under install\repair, so a user can attach one folder
// to a bug report. It returns the folder path.
func writeRepairBundle(root string, obs BootObservation, report BootRepairReport) (string, error) {
	stamp := time.Now().UTC().Format("20060102T150405Z")
	dir := filepath.Join(root, "install", "repair", stamp)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("creating repair bundle folder: %w", err)
	}
	var index []string
	for _, rel := range repairBundleSources {
		src := filepath.Join(root, rel)
		dst := filepath.Join(dir, strings.ReplaceAll(filepath.ToSlash(rel), "/", "__"))
		if err := copyRegularFile(src, dst); err != nil {
			index = append(index, "missing  "+filepath.ToSlash(rel))
			continue
		}
		index = append(index, "copied   "+filepath.ToSlash(rel))
	}
	if err := os.WriteFile(filepath.Join(dir, "bcdedit-enum-firmware.txt"), []byte(obs.FirmwareEnum+obs.FirmwareEnumErr), 0o644); err != nil {
		return "", err
	}
	if err := marshalJSONToFile(filepath.Join(dir, "observation.json"), obs); err != nil {
		return "", err
	}
	report.BundlePath = dir
	if err := marshalJSONToFile(filepath.Join(dir, "report.json"), report); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(dir, "index.txt"), []byte(strings.Join(index, "\n")+"\n"), 0o644); err != nil {
		return "", err
	}
	return dir, nil
}

func copyRegularFile(src, dst string) error {
	fi, err := os.Lstat(src)
	if err != nil {
		return err
	}
	if !fi.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file", src)
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// InspectBoot observes the boot chain, writes an evidence bundle, and
// returns the report. It changes nothing in BCD or on the ESP.
func inspectBoot() (BootRepairReport, BootObservation) {
	obs := observeBoot()
	report := planBootRepair(obs)
	if dir, err := writeRepairBundle(wootcDir(), obs, report); err == nil {
		report.BundlePath = dir
	} else {
		report.Findings = append(report.Findings, "could not write the repair bundle: "+err.Error())
	}
	return report, obs
}

// restoreWindowsBoot clears wootc's one-shot and removes wootc entries from
// the permanent boot order, then re-observes. It returns the post-action
// report; err is non-nil unless the re-observation shows a Windows-only boot.
func restoreWindowsBoot() (BootRepairReport, error) {
	before, _ := inspectBoot()
	cmds, err := restoreWindowsCommands(before)
	if err != nil {
		if before.BootState == BootStateWindowsOnly && before.Ownership != OwnershipUncertain {
			return before, nil // already there; nothing to change
		}
		return before, err
	}
	for _, args := range cmds {
		if out, err := runBCDEdit(args...); err != nil {
			return before, fmt.Errorf("bcdedit %s: %w (%s)", strings.Join(args, " "), err, strings.TrimSpace(out))
		}
	}
	after := planBootRepair(observeBoot())
	after.BundlePath = before.BundlePath
	if err := verifyWindowsOnly(after); err != nil {
		return after, err
	}
	return after, nil
}
