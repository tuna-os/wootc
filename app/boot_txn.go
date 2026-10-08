package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// ── Boot-chain transaction (#286) ─────────────────────────────────────────────
//
// Install changes the Windows boot configuration in several steps: it stages
// EFI files, creates a firmware entry, and arms a one-shot bootsequence. A
// cancel, a failure, or a power cut between any two of those steps used to
// leave a partly built chain: an entry with no path, an entry in the permanent
// firmware boot order, or an armed one-shot whose recovery records were never
// written (configureBCD armed BEFORE it wrote armed.json, and treated that
// write as a warning).
//
// The transaction makes the order and the proof explicit:
//
//	begun          journal written, nothing in BCD changed yet
//	creating-entry about to run `bcdedit /copy`; the GUID is not known yet
//	entry-created  the entry exists and its GUID is journaled
//	prepared       entry + ESP chain verified by observation; entry is INERT
//	               (in no boot order, no bootsequence)
//	arming         about to set the one-shot bootsequence
//	committed      the armed chain was observed exactly as intended
//	rolling-back   cleanup in progress
//	rolled-back    cleanup observed: no wootc entry, nothing in any boot order
//	rollback-unconfirmed  cleanup could not be observed; recovery retries
//
// The one-shot is the commit point and it is the LAST change before reboot
// (the pipeline arms it in "Finishing up"). Until then the entry is inert, so
// a power cut at any earlier boundary returns to Windows on the next start.
//
// Each step is checked against what bcdedit and the ESP report, never against
// the exit code of the command that tried to make the change: status derived
// from a proxy rather than an observable is this codebase's dominant bug class.
// When cleanup cannot be observed, the journal stays in rollback-unconfirmed
// and the startup recovery task tries again. wootc never reports a clean
// machine that it could not see.
//
// ESP files are NOT removed on rollback. With no entry pointing at them they
// are inert, the ownership manifest attributes every one of them to wootc, a
// retry reuses them, and uninstall removes them (esp_cleanup.go).

const (
	txnBegun               = "begun"
	txnCreatingEntry       = "creating-entry"
	txnEntryCreated        = "entry-created"
	txnPrepared            = "prepared"
	txnArming              = "arming"
	txnCommitted           = "committed"
	txnRollingBack         = "rolling-back"
	txnRolledBack          = "rolled-back"
	txnRollbackUnconfirmed = "rollback-unconfirmed"
)

// BootTxn is the boot-chain journal at C:\wootc\install\boot-txn.json.
type BootTxn struct {
	Phase string `json:"phase"`
	// BcdGuid is the firmware entry this transaction created ("" before /copy).
	BcdGuid string `json:"bcdGuid,omitempty"`
	// EfiPath is the loader the entry must point at, e.g. \EFI\fedora\shimx64.efi.
	EfiPath string `json:"efiPath"`
	// EspFileHashes is the staged ESP chain (ESP-relative path → SHA-256) the
	// entry is allowed to boot. Every file must still match before arming.
	EspFileHashes map[string]string `json:"espFileHashes"`
	StartedAt     string            `json:"startedAt"`
	UpdatedAt     string            `json:"updatedAt"`
	Error         string            `json:"error,omitempty"`
}

func bootTxnPath() string {
	return filepath.Join(wootcDir(), "install", "boot-txn.json")
}

func readBootTxn() (BootTxn, error) {
	data, err := os.ReadFile(bootTxnPath())
	if err != nil {
		return BootTxn{}, err
	}
	var txn BootTxn
	if err := unmarshalJSON(data, &txn); err != nil {
		return BootTxn{}, fmt.Errorf("parsing boot-txn.json: %w", err)
	}
	return txn, nil
}

func writeBootTxn(txn BootTxn) error {
	path := bootTxnPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := marshalJSON(txn)
	if err != nil {
		return err
	}
	// Synced temp file + rename: a power cut leaves the old journal or the
	// new one, never a truncated file.
	tmp := path + ".tmp"
	if err := writeFileSynced(tmp, string(data)); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// bootChainEnv is everything the transaction does to the machine. Windows
// wires it to bcdedit and the real ESP; tests wire it to a simulated store.
type bootChainEnv struct {
	bcdedit func(args ...string) (string, error)
	// hashESP returns the observed SHA-256 of each ESP-relative path. A path
	// that is missing or unreadable is absent from the result.
	hashESP func(rels []string) map[string]string
	saveTxn func(BootTxn) error
	// onEntry persists the records that recovery needs to find the entry
	// (bcd-guid.txt, armed.json). It runs before the entry can be armed, and
	// an error fails the attempt: an armed entry nobody can find is the
	// state this transaction exists to prevent.
	onEntry func(guid string) error
	sleep   func(time.Duration)
}

func (env bootChainEnv) save(txn *BootTxn, phase string) error {
	txn.Phase = phase
	txn.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	if err := env.saveTxn(*txn); err != nil {
		return fmt.Errorf("could not journal boot-chain step %q: %w", phase, err)
	}
	return nil
}

// ── bcdedit observation ──────────────────────────────────────────────────────

// bcdObject is one object from `bcdedit /enum firmware`. Field names are
// lower-cased; list elements (displayorder, bootsequence) keep every value.
type bcdObject struct {
	ID     string
	Fields map[string][]string
}

func (o bcdObject) first(key string) string {
	if v := o.Fields[key]; len(v) > 0 {
		return v[0]
	}
	return ""
}

var (
	bcdFieldLine = regexp.MustCompile(`^(\S+)\s{2,}(\S.*)$`)
	bcdGUIDRe    = regexp.MustCompile(`\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}`)
	bcdGUIDExact = regexp.MustCompile(`^` + bcdGUIDRe.String() + `$`)
)

// validBCDGUID accepts only a full braced GUID, never a well-known alias such
// as {bootmgr}: cleanup must not be able to delete something that is not ours.
func validBCDGUID(g string) bool { return bcdGUIDExact.MatchString(g) }

// parseBCDEnum parses bcdedit's two-column listing. Headings and their dash
// underlines are skipped; an indented line continues the previous field.
func parseBCDEnum(out string) []bcdObject {
	var objs []bcdObject
	cur := -1
	lastKey := ""
	for _, raw := range strings.Split(strings.ReplaceAll(out, "\r\n", "\n"), "\n") {
		line := strings.TrimRight(raw, " \t\r")
		if strings.TrimSpace(line) == "" {
			cur, lastKey = -1, ""
			continue
		}
		if strings.Trim(line, "-") == "" {
			continue
		}
		if line[0] == ' ' || line[0] == '\t' {
			if cur >= 0 && lastKey != "" {
				objs[cur].Fields[lastKey] = append(objs[cur].Fields[lastKey], strings.TrimSpace(line))
			}
			continue
		}
		m := bcdFieldLine.FindStringSubmatch(line)
		if m == nil {
			cur, lastKey = -1, "" // a heading starts the next object
			continue
		}
		key, val := strings.ToLower(m[1]), strings.TrimSpace(m[2])
		if key == "identifier" {
			objs = append(objs, bcdObject{ID: val, Fields: map[string][]string{}})
			cur = len(objs) - 1
		}
		if cur < 0 {
			continue
		}
		objs[cur].Fields[key] = append(objs[cur].Fields[key], val)
		lastKey = key
	}
	return objs
}

func findBCDObject(objs []bcdObject, id string) *bcdObject {
	for i := range objs {
		if strings.EqualFold(objs[i].ID, id) {
			return &objs[i]
		}
	}
	return nil
}

func containsID(list []string, id string) bool {
	for _, v := range list {
		if strings.EqualFold(v, id) {
			return true
		}
	}
	return false
}

// wootcEntryIDs returns every firmware entry that is ours: described exactly
// "wootc", or the GUID this transaction journaled.
func wootcEntryIDs(objs []bcdObject, guid string) []string {
	var ids []string
	for _, o := range objs {
		if !validBCDGUID(o.ID) {
			continue
		}
		if strings.EqualFold(o.first("description"), "wootc") || (guid != "" && strings.EqualFold(o.ID, guid)) {
			ids = append(ids, o.ID)
		}
	}
	if validBCDGUID(guid) && !containsID(ids, guid) {
		ids = append(ids, guid) // gone from the listing but maybe still in an order
	}
	return ids
}

// tail returns the last n bytes of s, for embedding a bounded slice of a
// command dump in an error without flooding the GUI.
func tail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return "..." + s[len(s)-n:]
}

func observeFirmware(env bootChainEnv) ([]bcdObject, error) {
	out, err := env.bcdedit("/enum", "firmware")
	if err != nil {
		return nil, fmt.Errorf("could not read the firmware boot entries: %w (output: %s)", err, tail(out, 400))
	}
	objs := parseBCDEnum(out)
	if findBCDObject(objs, "{fwbootmgr}") == nil {
		// An empty or unparsable listing is not "nothing is there".
		return nil, fmt.Errorf("firmware boot manager not found in bcdedit output (%d bytes)", len(out))
	}
	return objs, nil
}

// ── verification ─────────────────────────────────────────────────────────────

// espChainProblems checks the staged EFI files the entry will boot: the loader
// must be one wootc staged, and each staged file must still match its hash.
func espChainProblems(efiPath string, staged, observed map[string]string) []string {
	var problems []string
	if len(staged) == 0 {
		return []string{"no staged ESP files are recorded for this boot chain"}
	}
	loader := normalizeESPPath(efiPath)
	found := false
	for rel := range staged {
		if normalizeESPPath(rel) == loader {
			found = true
		}
	}
	if !found {
		problems = append(problems, fmt.Sprintf("boot loader %s is not a file wootc staged on the ESP", efiPath))
	}
	rels := make([]string, 0, len(staged))
	for rel := range staged {
		rels = append(rels, rel)
	}
	sort.Strings(rels)
	for _, rel := range rels {
		got, ok := observed[rel]
		switch {
		case !ok:
			problems = append(problems, fmt.Sprintf("ESP file %s is missing", rel))
		case !strings.EqualFold(got, staged[rel]):
			problems = append(problems, fmt.Sprintf("ESP file %s changed after staging", rel))
		}
	}
	return problems
}

// bootChainProblems compares the observed firmware state with the chain this
// transaction intends. wantArmed selects the prepared (inert) or committed
// (one-shot armed) shape. An empty result is the only success.
func bootChainProblems(objs []bcdObject, txn BootTxn, observedESP map[string]string, wantArmed bool) []string {
	var problems []string
	fw := findBCDObject(objs, "{fwbootmgr}")
	if fw == nil {
		return []string{"firmware boot manager not visible"}
	}
	if !validBCDGUID(txn.BcdGuid) {
		return []string{fmt.Sprintf("journaled entry id %q is not a GUID", txn.BcdGuid)}
	}
	entry := findBCDObject(objs, txn.BcdGuid)
	if entry == nil {
		problems = append(problems, fmt.Sprintf("entry %s is missing", txn.BcdGuid))
	} else {
		if d := entry.first("description"); !strings.EqualFold(d, "wootc") {
			problems = append(problems, fmt.Sprintf("entry %s is described %q, not wootc", txn.BcdGuid, d))
		}
		if p := entry.first("path"); !strings.EqualFold(p, txn.EfiPath) {
			problems = append(problems, fmt.Sprintf("entry %s boots %q, not %s", txn.BcdGuid, p, txn.EfiPath))
		}
	}
	for _, id := range wootcEntryIDs(objs, "") {
		if !strings.EqualFold(id, txn.BcdGuid) {
			problems = append(problems, fmt.Sprintf("stale wootc entry %s is still present", id))
		}
	}
	if containsID(fw.Fields["displayorder"], txn.BcdGuid) {
		problems = append(problems, fmt.Sprintf("entry %s is in the permanent firmware boot order", txn.BcdGuid))
	}
	seq := fw.Fields["bootsequence"]
	if wantArmed {
		if len(seq) == 0 || !strings.EqualFold(seq[0], txn.BcdGuid) {
			problems = append(problems, fmt.Sprintf("one-shot bootsequence is %v, not %s first", seq, txn.BcdGuid))
		}
	} else if containsID(seq, txn.BcdGuid) {
		problems = append(problems, fmt.Sprintf("entry %s is armed before the chain was committed", txn.BcdGuid))
	}
	return append(problems, espChainProblems(txn.EfiPath, txn.EspFileHashes, observedESP)...)
}

// bootChainResidue lists what rollback must still remove. Empty means the
// next start goes to Windows and no wootc entry is left behind.
func bootChainResidue(objs []bcdObject, guid string) []string {
	var residue []string
	fw := findBCDObject(objs, "{fwbootmgr}")
	for _, id := range wootcEntryIDs(objs, guid) {
		if findBCDObject(objs, id) != nil {
			residue = append(residue, fmt.Sprintf("entry %s still exists", id))
		}
		if fw != nil && containsID(fw.Fields["bootsequence"], id) {
			residue = append(residue, fmt.Sprintf("entry %s is still in the one-shot bootsequence", id))
		}
		if fw != nil && containsID(fw.Fields["displayorder"], id) {
			residue = append(residue, fmt.Sprintf("entry %s is still in the firmware boot order", id))
		}
	}
	return residue
}

// ── transaction steps ────────────────────────────────────────────────────────

func stagedRels(staged map[string]string) []string {
	rels := make([]string, 0, len(staged))
	for rel := range staged {
		rels = append(rels, rel)
	}
	sort.Strings(rels)
	return rels
}

// sweepWootcEntries removes every wootc entry from the one-shot, the boot
// order, and the store. It touches only wootc GUIDs: a bootsequence that also
// names a foreign entry loses only our element. Command errors are ignored on
// purpose; the caller observes the result.
func sweepWootcEntries(env bootChainEnv, guid string) {
	objs, err := observeFirmware(env)
	if err != nil {
		// Without a listing, fall back to the journaled GUID only.
		if validBCDGUID(guid) {
			env.bcdedit("/set", "{fwbootmgr}", "bootsequence", guid, "/remove") //nolint:errcheck
			env.bcdedit("/set", "{fwbootmgr}", "displayorder", guid, "/remove") //nolint:errcheck
			env.bcdedit("/delete", guid)                                        //nolint:errcheck
		}
		return
	}
	ids := wootcEntryIDs(objs, guid)
	if fw := findBCDObject(objs, "{fwbootmgr}"); fw != nil {
		seq := fw.Fields["bootsequence"]
		onlyOurs := len(seq) > 0
		for _, s := range seq {
			if !containsID(ids, s) {
				onlyOurs = false
			}
		}
		if onlyOurs {
			env.bcdedit("/deletevalue", "{fwbootmgr}", "bootsequence") //nolint:errcheck
		} else {
			for _, s := range seq {
				if containsID(ids, s) {
					env.bcdedit("/set", "{fwbootmgr}", "bootsequence", s, "/remove") //nolint:errcheck
				}
			}
		}
	}
	for _, id := range ids {
		env.bcdedit("/set", "{fwbootmgr}", "displayorder", id, "/remove") //nolint:errcheck
		env.bcdedit("/delete", id)                                        //nolint:errcheck
	}
}

// buildBootEntry creates one inert entry and proves it by observation.
func buildBootEntry(env bootChainEnv, txn *BootTxn) error {
	sweepWootcEntries(env, txn.BcdGuid)
	txn.BcdGuid = ""
	// Dangling references left by a swept entry make /copy fail when it reads
	// the display order, so repair it first (idempotent).
	env.bcdedit("/displayorder", "{bootmgr}", "/addfirst") //nolint:errcheck
	if err := env.save(txn, txnCreatingEntry); err != nil {
		return err
	}
	// /copy {bootmgr} clones the Windows Boot Manager entry and inherits its
	// ESP device, so no drive letter is needed (the WubiUEFI approach).
	out, err := env.bcdedit("/copy", "{bootmgr}", "/d", "wootc")
	if err != nil {
		return fmt.Errorf("bcdedit /copy: %w (output: %s)", err, out)
	}
	guid := bcdGUIDRe.FindString(out)
	if guid == "" {
		return fmt.Errorf("could not parse GUID from bcdedit output: %q", out)
	}
	txn.BcdGuid = guid
	if err := env.save(txn, txnEntryCreated); err != nil {
		return err
	}
	if out, err := env.bcdedit("/set", guid, "path", txn.EfiPath); err != nil {
		return fmt.Errorf("bcdedit /set path: %w (output: %s)", err, out)
	}
	// /copy can register the clone in the permanent displayorder (position
	// varies by firmware). An entry there outlives the one-shot, so it is
	// removed; firmware that never added it reports a harmless error.
	env.bcdedit("/set", "{fwbootmgr}", "displayorder", guid, "/remove") //nolint:errcheck
	if err := env.onEntry(guid); err != nil {
		return fmt.Errorf("could not record boot entry %s for recovery: %w", guid, err)
	}
	objs, err := observeFirmware(env)
	if err != nil {
		return err
	}
	if p := bootChainProblems(objs, *txn, env.hashESP(stagedRels(txn.EspFileHashes)), false); len(p) > 0 {
		return fmt.Errorf("boot entry not verified: %s", strings.Join(p, "; "))
	}
	return nil
}

// beginBootChainTxn verifies the staged ESP chain, then builds an inert,
// verified entry. On failure everything it changed is rolled back.
func beginBootChainTxn(env bootChainEnv, efiPath string, staged map[string]string) (BootTxn, error) {
	now := time.Now().UTC().Format(time.RFC3339)
	txn := BootTxn{EfiPath: efiPath, EspFileHashes: staged, StartedAt: now}
	// Nothing in BCD has changed yet, so these two refusals need no rollback.
	if p := espChainProblems(efiPath, staged, env.hashESP(stagedRels(staged))); len(p) > 0 {
		return txn, fmt.Errorf("staged boot files not verified, BCD left unchanged: %s", strings.Join(p, "; "))
	}
	if err := env.save(&txn, txnBegun); err != nil {
		return txn, fmt.Errorf("%w — BCD left unchanged", err)
	}
	var err error
	for attempt := 1; attempt <= 3; attempt++ {
		if err = buildBootEntry(env, &txn); err == nil {
			if err = env.save(&txn, txnPrepared); err == nil {
				return txn, nil
			}
		}
		if attempt < 3 {
			env.sleep(time.Duration(attempt) * 2 * time.Second)
		}
	}
	return rollbackAfter(env, txn, fmt.Errorf("creating the boot entry: %w", err))
}

// armBootChainTxn sets the one-shot — the commit point — and proves it. A
// failed arm rebuilds the entry from /copy: an entry whose registry key went
// bad ("marked for deletion", #74) cannot be repaired by re-running one
// command against it.
func armBootChainTxn(env bootChainEnv, txn BootTxn) (BootTxn, error) {
	if txn.Phase != txnPrepared && txn.Phase != txnArming {
		return txn, fmt.Errorf("boot chain is %q, not prepared; refusing to arm it", txn.Phase)
	}
	var err error
	for attempt := 1; attempt <= 3; attempt++ {
		if attempt > 1 {
			env.sleep(time.Duration(attempt) * 2 * time.Second)
			if err = buildBootEntry(env, &txn); err != nil {
				continue
			}
		}
		if err = env.save(&txn, txnArming); err != nil {
			continue
		}
		var out string
		if out, err = env.bcdedit("/set", "{fwbootmgr}", "bootsequence", txn.BcdGuid, "/addfirst"); err != nil {
			err = fmt.Errorf("bcdedit bootsequence: %w (output: %s)", err, out)
			continue
		}
		var objs []bcdObject
		if objs, err = observeFirmware(env); err != nil {
			continue
		}
		if p := bootChainProblems(objs, txn, env.hashESP(stagedRels(txn.EspFileHashes)), true); len(p) > 0 {
			err = fmt.Errorf("armed boot chain not verified: %s", strings.Join(p, "; "))
			continue
		}
		if err = env.save(&txn, txnCommitted); err == nil {
			return txn, nil
		}
	}
	return rollbackAfter(env, txn, fmt.Errorf("arming the one-time boot: %w", err))
}

func rollbackAfter(env bootChainEnv, txn BootTxn, cause error) (BootTxn, error) {
	txn.Error = cause.Error()
	txn, rbErr := rollbackBootChainTxn(env, txn)
	if rbErr != nil {
		return txn, fmt.Errorf("%w; %v", cause, rbErr)
	}
	return txn, fmt.Errorf("%w (boot changes rolled back; Windows starts normally)", cause)
}

// rollbackBootChainTxn removes every wootc entry and one-shot and then looks.
// It fails closed: a residue it can still see, or a listing it cannot read,
// leaves the journal in rollback-unconfirmed and returns an error.
func rollbackBootChainTxn(env bootChainEnv, txn BootTxn) (BootTxn, error) {
	_ = env.save(&txn, txnRollingBack) // keep going: cleanup matters more than the record
	var problems []string
	for attempt := 1; attempt <= 2; attempt++ {
		sweepWootcEntries(env, txn.BcdGuid)
		objs, err := observeFirmware(env)
		if err != nil {
			problems = []string{err.Error()}
		} else if problems = bootChainResidue(objs, txn.BcdGuid); len(problems) == 0 {
			if err := env.save(&txn, txnRolledBack); err != nil {
				return txn, err
			}
			return txn, nil
		}
		if attempt < 2 {
			env.sleep(2 * time.Second)
		}
	}
	msg := "boot-chain rollback not confirmed: " + strings.Join(problems, "; ")
	if txn.Error != "" {
		txn.Error += "; " + msg
	} else {
		txn.Error = msg
	}
	_ = env.save(&txn, txnRollbackUnconfirmed)
	return txn, fmt.Errorf("%s", msg)
}

// ── startup recovery ─────────────────────────────────────────────────────────

const (
	bootTxnKeep          = "keep"
	bootTxnRollback      = "rollback"
	bootTxnMarkCommitted = "mark-committed"
)

// bootTxnStartupAction decides what the startup recovery task does with a
// journal it finds. Any phase short of committed means the install never
// reached its commit point, so its changes are rolled back. The one exception
// is "arming": the power can fail after the firmware stored the one-shot but
// before the journal said so. If the deployer then started, the chain proved
// itself by booting and must be kept for Phase 2.
func bootTxnStartupAction(txn BootTxn, deployerStarted bool, ls LifecycleState) string {
	switch txn.Phase {
	case txnCommitted, txnRolledBack:
		return bootTxnKeep
	case txnArming:
		if deployerStarted || ls.State == StateDeploying || ls.State == StateDeployed || ls.State == StateHealthy {
			return bootTxnMarkCommitted
		}
		return bootTxnRollback
	default:
		return bootTxnRollback
	}
}
