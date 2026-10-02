package main

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

// fakeBCD simulates the firmware half of the BCD store closely enough to
// drive the transaction through every boundary: entries, the permanent
// displayorder, the one-shot bootsequence, and bcdedit's text listing.
type fakeBCD struct {
	entries     map[string]*fakeEntry
	order       []string // {fwbootmgr} displayorder
	seq         []string // {fwbootmgr} bootsequence
	next        int
	mutations   int
	steps       int                              // mutations + journal writes, the power-cut clock
	failOn      func(n int, args []string) error // per-mutation fault
	crashAt     int                              // panic on this mutation (power cut)
	copyInOrder bool                             // firmware that adds /copy clones to displayorder
	undeletable map[string]bool
	enumFails   bool
}

type fakeEntry struct{ desc, path string }

type powerCut struct{}

const foreignGUID = "{11111111-2222-3333-4444-555555555555}"

func newFakeBCD() *fakeBCD {
	return &fakeBCD{
		entries: map[string]*fakeEntry{
			"{bootmgr}": {desc: "Windows Boot Manager", path: `\EFI\Microsoft\Boot\bootmgfw.efi`},
			foreignGUID: {desc: "Fedora", path: `\EFI\fedora\shimx64.efi`},
		},
		order:       []string{"{bootmgr}", foreignGUID},
		undeletable: map[string]bool{},
	}
}

func removeID(list []string, id string) ([]string, bool) {
	for i, v := range list {
		if strings.EqualFold(v, id) {
			return append(append([]string{}, list[:i]...), list[i+1:]...), true
		}
	}
	return list, false
}

func (f *fakeBCD) bcdedit(args ...string) (string, error) {
	if len(args) >= 1 && args[0] == "/enum" {
		if f.enumFails {
			return "The boot configuration data store could not be opened.", fmt.Errorf("exit status 1")
		}
		return f.render(), nil
	}
	f.mutations++
	f.tick()
	if f.failOn != nil {
		if err := f.failOn(f.mutations, args); err != nil {
			return "An error occurred: " + err.Error(), err
		}
	}
	switch {
	case args[0] == "/displayorder":
		return "The operation completed successfully.", nil
	case args[0] == "/copy":
		f.next++
		g := fmt.Sprintf("{aaaaaaaa-0000-0000-0000-%012d}", f.next)
		f.entries[g] = &fakeEntry{desc: args[3], path: `\EFI\Microsoft\Boot\bootmgfw.efi`}
		if f.copyInOrder {
			f.order = append(f.order, g)
		}
		return "The entry was successfully copied to " + g + ".", nil
	case args[0] == "/delete":
		if _, ok := f.entries[args[1]]; !ok || f.undeletable[args[1]] {
			return "", fmt.Errorf("delete failed")
		}
		delete(f.entries, args[1])
		f.order, _ = removeID(f.order, args[1])
		f.seq, _ = removeID(f.seq, args[1])
		return "The operation completed successfully.", nil
	case args[0] == "/deletevalue":
		if f.seq == nil {
			return "", fmt.Errorf("element not found")
		}
		f.seq = nil
		return "The operation completed successfully.", nil
	case args[0] == "/set" && args[1] == "{fwbootmgr}":
		list := &f.order
		if args[2] == "bootsequence" {
			list = &f.seq
		}
		switch args[4] {
		case "/remove":
			var ok bool
			if *list, ok = removeID(*list, args[3]); !ok {
				return "", fmt.Errorf("not in list")
			}
		case "/addfirst":
			if _, ok := f.entries[args[3]]; !ok {
				return "", fmt.Errorf("no such entry")
			}
			l, _ := removeID(*list, args[3])
			*list = append([]string{args[3]}, l...)
		}
		return "The operation completed successfully.", nil
	case args[0] == "/set" && args[2] == "path":
		e, ok := f.entries[args[1]]
		if !ok {
			return "", fmt.Errorf("no such entry")
		}
		e.path = args[3]
		return "The operation completed successfully.", nil
	}
	return "", fmt.Errorf("fake bcdedit: unhandled %v", args)
}

// tick advances the power-cut clock; the cut lands BEFORE the step runs.
func (f *fakeBCD) tick() {
	f.steps++
	if f.crashAt > 0 && f.steps == f.crashAt {
		panic(powerCut{})
	}
}

func (f *fakeBCD) render() string {
	var b strings.Builder
	field := func(k string, vals ...string) {
		for i, v := range vals {
			if i == 0 {
				fmt.Fprintf(&b, "%-24s%s\r\n", k, v)
			} else {
				fmt.Fprintf(&b, "%-24s%s\r\n", "", v)
			}
		}
	}
	b.WriteString("Firmware Boot Manager\r\n---------------------\r\n")
	field("identifier", "{fwbootmgr}")
	if len(f.order) > 0 {
		field("displayorder", f.order...)
	}
	if len(f.seq) > 0 {
		field("bootsequence", f.seq...)
	}
	field("timeout", "0")
	for _, id := range append([]string{"{bootmgr}"}, f.ids()...) {
		e := f.entries[id]
		if e == nil {
			continue
		}
		b.WriteString("\r\nFirmware Application (101fffff)\r\n-------------------------------\r\n")
		field("identifier", id)
		field("device", `partition=\Device\HarddiskVolume1`)
		field("path", e.path)
		field("description", e.desc)
	}
	return b.String()
}

func (f *fakeBCD) ids() []string {
	var ids []string
	for id := range f.entries {
		if id != "{bootmgr}" {
			ids = append(ids, id)
		}
	}
	return ids
}

func (f *fakeBCD) wootcResidue() []string {
	objs := parseBCDEnum(f.render())
	return bootChainResidue(objs, "")
}

type txnHarness struct {
	bcd      *fakeBCD
	esp      map[string]string
	journal  BootTxn
	saves    []string
	recorded []string
}

const testLoader = `\EFI\fedora\shimx64.efi`

func stagedChain() map[string]string {
	return map[string]string{
		"EFI/fedora/shimx64.efi": "aa",
		"EFI/fedora/grubx64.efi": "bb",
		"EFI/fedora/grub.cfg":    "cc",
	}
}

func newHarness() *txnHarness {
	h := &txnHarness{bcd: newFakeBCD(), esp: stagedChain()}
	return h
}

func (h *txnHarness) env() bootChainEnv {
	return bootChainEnv{
		bcdedit: h.bcd.bcdedit,
		hashESP: func(rels []string) map[string]string {
			out := map[string]string{}
			for _, r := range rels {
				if v, ok := h.esp[r]; ok {
					out[r] = v
				}
			}
			return out
		},
		saveTxn: func(t BootTxn) error {
			h.bcd.tick()
			h.journal = t
			h.saves = append(h.saves, t.Phase)
			return nil
		},
		onEntry: func(g string) error { h.recorded = append(h.recorded, g); return nil },
		sleep:   func(time.Duration) {},
	}
}

func (h *txnHarness) install() (err error) {
	env := h.env()
	txn, err := beginBootChainTxn(env, testLoader, stagedChain())
	if err != nil {
		return err
	}
	_, err = armBootChainTxn(env, txn)
	return err
}

func assertCommittedChain(t *testing.T, h *txnHarness) {
	t.Helper()
	if h.journal.Phase != txnCommitted {
		t.Fatalf("journal phase = %q, want committed (saves %v)", h.journal.Phase, h.saves)
	}
	g := h.journal.BcdGuid
	e := h.bcd.entries[g]
	if e == nil || e.path != testLoader || e.desc != "wootc" {
		t.Fatalf("entry %s = %+v", g, e)
	}
	if len(h.bcd.seq) != 1 || h.bcd.seq[0] != g {
		t.Fatalf("bootsequence = %v, want [%s]", h.bcd.seq, g)
	}
	if _, in := removeID(h.bcd.order, g); in {
		t.Fatalf("wootc entry leaked into permanent displayorder %v", h.bcd.order)
	}
	if len(h.bcd.ids()) != 2 {
		t.Fatalf("expected exactly the foreign entry and ours, got %v", h.bcd.ids())
	}
	if h.recorded[len(h.recorded)-1] != g {
		t.Fatalf("recovery records name %v, entry is %s", h.recorded, g)
	}
}

func assertWindowsOnly(t *testing.T, h *txnHarness) {
	t.Helper()
	if r := h.bcd.wootcResidue(); len(r) > 0 {
		t.Fatalf("wootc residue after rollback: %v", r)
	}
	if h.bcd.entries[foreignGUID] == nil {
		t.Fatalf("foreign entry was deleted")
	}
	if len(h.bcd.order) != 2 || h.bcd.order[0] != "{bootmgr}" || h.bcd.order[1] != foreignGUID {
		t.Fatalf("permanent boot order changed: %v", h.bcd.order)
	}
	if h.journal.Phase != txnRolledBack {
		t.Fatalf("journal phase = %q, want rolled-back", h.journal.Phase)
	}
}

func TestBootTxnCommitsVerifiedChain(t *testing.T) {
	h := newHarness()
	h.bcd.copyInOrder = true // firmware that adds the clone to the permanent order
	if err := h.install(); err != nil {
		t.Fatal(err)
	}
	assertCommittedChain(t, h)
	// Prepared before armed: the one-shot is the last change.
	want := []string{txnBegun, txnCreatingEntry, txnEntryCreated, txnPrepared, txnArming, txnCommitted}
	if strings.Join(h.saves, ",") != strings.Join(want, ",") {
		t.Fatalf("journal order = %v, want %v", h.saves, want)
	}
}

func TestBootTxnPreparedEntryIsInert(t *testing.T) {
	h := newHarness()
	h.bcd.copyInOrder = true
	txn, err := beginBootChainTxn(h.env(), testLoader, stagedChain())
	if err != nil {
		t.Fatal(err)
	}
	if txn.Phase != txnPrepared {
		t.Fatalf("phase = %q", txn.Phase)
	}
	if len(h.bcd.seq) != 0 {
		t.Fatalf("prepared chain is armed: %v", h.bcd.seq)
	}
	if _, in := removeID(h.bcd.order, txn.BcdGuid); in {
		t.Fatalf("prepared entry is in the boot order %v", h.bcd.order)
	}
}

func TestBootTxnRefusesUnverifiedESPWithoutTouchingBCD(t *testing.T) {
	cases := map[string]func(h *txnHarness){
		"missing file":  func(h *txnHarness) { delete(h.esp, "EFI/fedora/grubx64.efi") },
		"changed file":  func(h *txnHarness) { h.esp["EFI/fedora/grub.cfg"] = "zz" },
		"loader absent": func(h *txnHarness) {},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			h := newHarness()
			mutate(h)
			loader := testLoader
			if name == "loader absent" {
				loader = `\EFI\systemd\systemd-bootx64.efi`
			}
			_, err := beginBootChainTxn(h.env(), loader, stagedChain())
			if err == nil {
				t.Fatal("unverified ESP chain was accepted")
			}
			if h.bcd.mutations != 0 {
				t.Fatalf("BCD changed %d times before the ESP chain was verified", h.bcd.mutations)
			}
		})
	}
}

// Each command the chain cannot be built without fails persistently, and so
// do the recovery records. Install returns an error and BCD is back to Windows.
func TestBootTxnRollsBackFailureAtEveryStep(t *testing.T) {
	isCopy := func(a []string) bool { return a[0] == "/copy" }
	isPath := func(a []string) bool { return a[0] == "/set" && len(a) > 2 && a[2] == "path" }
	isArm := func(a []string) bool {
		return a[0] == "/set" && len(a) > 4 && a[2] == "bootsequence" && a[4] == "/addfirst"
	}
	for name, match := range map[string]func([]string) bool{"copy": isCopy, "path": isPath, "arm": isArm} {
		t.Run(name, func(t *testing.T) {
			h := newHarness()
			h.bcd.copyInOrder = true
			h.bcd.failOn = func(_ int, args []string) error {
				if match(args) {
					return fmt.Errorf("simulated bcdedit failure")
				}
				return nil
			}
			if err := h.install(); err == nil {
				t.Fatal("install succeeded with a step that always fails")
			}
			assertWindowsOnly(t, h)
		})
	}
	t.Run("recovery records", func(t *testing.T) {
		h := newHarness()
		env := h.env()
		env.onEntry = func(string) error { return fmt.Errorf("disk full") }
		if _, err := beginBootChainTxn(env, testLoader, stagedChain()); err == nil {
			t.Fatal("entry kept although recovery could not find it")
		}
		assertWindowsOnly(t, h)
	})
	t.Run("path silently ignored", func(t *testing.T) {
		// bcdedit says it worked but the entry still boots bootmgfw.efi: only
		// observation catches it.
		h := newHarness()
		h.bcd.failOn = func(_ int, args []string) error {
			if isPath(args) {
				args[3] = `\EFI\Microsoft\Boot\bootmgfw.efi`
			}
			return nil
		}
		if err := h.install(); err == nil {
			t.Fatal("unverified path accepted")
		}
		assertWindowsOnly(t, h)
	})
}

// A power cut at every mutation boundary, followed by the next Windows start
// running the startup recovery decision on the journal that survived.
func TestBootTxnPowerCutAtEveryBoundary(t *testing.T) {
	clean := newHarness()
	if err := clean.install(); err != nil {
		t.Fatal(err)
	}
	if clean.bcd.steps < 10 {
		t.Fatalf("only %d boundaries exercised", clean.bcd.steps)
	}
	for cut := 1; cut <= clean.bcd.steps; cut++ {
		t.Run(fmt.Sprintf("cut-%d", cut), func(t *testing.T) {
			h := newHarness()
			h.bcd.crashAt = cut
			func() {
				defer func() {
					if r := recover(); r != nil {
						if _, ok := r.(powerCut); !ok {
							panic(r)
						}
					}
				}()
				_ = h.install()
			}()
			h.bcd.crashAt = 0
			// Firmware consumes the one-shot. It may only name a wootc entry
			// whose chain was already verified before the arm.
			armedWootc := false
			for _, id := range h.bcd.seq {
				if e := h.bcd.entries[id]; e != nil && e.desc == "wootc" {
					armedWootc = true
					if h.journal.Phase != txnArming && h.journal.Phase != txnCommitted {
						t.Fatalf("one-shot armed while journal is %q", h.journal.Phase)
					}
					if e.path != testLoader {
						t.Fatalf("armed entry boots %q", e.path)
					}
				}
			}
			if armedWootc {
				return // the deployer boots; the chain was verified before the arm
			}
			switch act := bootTxnStartupAction(h.journal, false, LifecycleState{}); act {
			case bootTxnRollback:
				if _, err := rollbackBootChainTxn(h.env(), h.journal); err != nil {
					t.Fatal(err)
				}
				assertWindowsOnly(t, h)
			default:
				t.Fatalf("startup action %q for journal %q with nothing armed", act, h.journal.Phase)
			}
		})
	}
}

func TestBootTxnTransientArmFailureRebuildsEntry(t *testing.T) {
	h := newHarness()
	failed := false
	h.bcd.failOn = func(n int, args []string) error {
		if !failed && len(args) > 4 && args[2] == "bootsequence" && args[4] == "/addfirst" {
			failed = true
			return fmt.Errorf("Illegal operation attempted on a registry key that has been marked for deletion")
		}
		return nil
	}
	if err := h.install(); err != nil {
		t.Fatal(err)
	}
	assertCommittedChain(t, h)
	if len(h.recorded) != 2 || h.recorded[0] == h.recorded[1] {
		t.Fatalf("rebuilt entry was not re-recorded: %v", h.recorded)
	}
}

func TestBootTxnRollbackFailsClosed(t *testing.T) {
	t.Run("undeletable entry", func(t *testing.T) {
		h := newHarness()
		txn, err := beginBootChainTxn(h.env(), testLoader, stagedChain())
		if err != nil {
			t.Fatal(err)
		}
		h.bcd.undeletable[txn.BcdGuid] = true
		if _, err := rollbackBootChainTxn(h.env(), txn); err == nil {
			t.Fatal("rollback reported success with the entry still present")
		}
		if h.journal.Phase != txnRollbackUnconfirmed {
			t.Fatalf("phase = %q", h.journal.Phase)
		}
		if bootTxnStartupAction(h.journal, false, LifecycleState{}) != bootTxnRollback {
			t.Fatal("startup recovery would not retry an unconfirmed rollback")
		}
	})
	t.Run("unreadable store", func(t *testing.T) {
		h := newHarness()
		txn, err := beginBootChainTxn(h.env(), testLoader, stagedChain())
		if err != nil {
			t.Fatal(err)
		}
		h.bcd.enumFails = true
		if _, err := rollbackBootChainTxn(h.env(), txn); err == nil {
			t.Fatal("rollback reported success without observing BCD")
		}
		if h.journal.Phase != txnRollbackUnconfirmed {
			t.Fatalf("phase = %q", h.journal.Phase)
		}
		// The journaled GUID was still removed without a listing.
		if h.bcd.entries[txn.BcdGuid] != nil {
			t.Fatal("blind fallback did not delete the journaled entry")
		}
	})
}

func TestBootTxnSweepKeepsForeignOneShot(t *testing.T) {
	h := newHarness()
	txn, err := beginBootChainTxn(h.env(), testLoader, stagedChain())
	if err != nil {
		t.Fatal(err)
	}
	h.bcd.seq = []string{txn.BcdGuid, foreignGUID}
	if _, err := rollbackBootChainTxn(h.env(), txn); err != nil {
		t.Fatal(err)
	}
	if len(h.bcd.seq) != 1 || h.bcd.seq[0] != foreignGUID {
		t.Fatalf("foreign one-shot lost: %v", h.bcd.seq)
	}
	assertWindowsOnly(t, h)
}

func TestBootTxnArmRefusesUnpreparedJournal(t *testing.T) {
	h := newHarness()
	if _, err := armBootChainTxn(h.env(), BootTxn{Phase: txnRolledBack}); err == nil {
		t.Fatal("armed a rolled-back chain")
	}
	if h.bcd.mutations != 0 {
		t.Fatal("BCD changed")
	}
}

func TestBootTxnStartupAction(t *testing.T) {
	cases := []struct {
		phase   string
		started bool
		state   string
		want    string
	}{
		{txnCommitted, false, "", bootTxnKeep},
		{txnRolledBack, false, "", bootTxnKeep},
		{txnBegun, false, "", bootTxnRollback},
		{txnCreatingEntry, false, "", bootTxnRollback},
		{txnEntryCreated, false, "", bootTxnRollback},
		{txnPrepared, false, StateStaged, bootTxnRollback},
		{txnRollingBack, false, "", bootTxnRollback},
		{txnRollbackUnconfirmed, false, "", bootTxnRollback},
		{txnArming, false, "", bootTxnRollback},
		{txnArming, true, "", bootTxnMarkCommitted},
		{txnArming, false, StateDeployed, bootTxnMarkCommitted},
		{"", false, "", bootTxnRollback}, // unparsable journal
	}
	for _, c := range cases {
		got := bootTxnStartupAction(BootTxn{Phase: c.phase}, c.started, LifecycleState{State: c.state})
		if got != c.want {
			t.Errorf("phase %q started=%v state=%q: got %q, want %q", c.phase, c.started, c.state, got, c.want)
		}
	}
}

func TestParseBCDEnum(t *testing.T) {
	out := "Firmware Boot Manager\r\n" +
		"---------------------\r\n" +
		"identifier              {fwbootmgr}\r\n" +
		"displayorder            {bootmgr}\r\n" +
		"                        {aaaaaaaa-0000-0000-0000-000000000001}\r\n" +
		"bootsequence            {AAAAAAAA-0000-0000-0000-000000000001}\r\n" +
		"timeout                 0\r\n" +
		"\r\n" +
		"Windows Boot Manager\r\n" +
		"--------------------\r\n" +
		"identifier              {bootmgr}\r\n" +
		"path                    \\EFI\\Microsoft\\Boot\\bootmgfw.efi\r\n" +
		"description             Windows Boot Manager\r\n" +
		"\r\n" +
		"Firmware Application (101fffff)\r\n" +
		"-------------------------------\r\n" +
		"identifier              {aaaaaaaa-0000-0000-0000-000000000001}\r\n" +
		"path                    \\EFI\\fedora\\shimx64.efi\r\n" +
		"description             wootc\r\n"
	objs := parseBCDEnum(out)
	if len(objs) != 3 {
		t.Fatalf("parsed %d objects: %+v", len(objs), objs)
	}
	fw := findBCDObject(objs, "{fwbootmgr}")
	if fw == nil || len(fw.Fields["displayorder"]) != 2 || fw.first("timeout") != "0" {
		t.Fatalf("fwbootmgr = %+v", fw)
	}
	ids := wootcEntryIDs(objs, "")
	if len(ids) != 1 || ids[0] != "{aaaaaaaa-0000-0000-0000-000000000001}" {
		t.Fatalf("wootc ids = %v", ids)
	}
	// Case-insensitive: bcdedit is not consistent about GUID case.
	if r := bootChainResidue(objs, ""); len(r) != 3 {
		t.Fatalf("residue = %v", r)
	}
}

func TestValidBCDGUIDRejectsAliases(t *testing.T) {
	for _, g := range []string{"{bootmgr}", "{fwbootmgr}", "{current}", "{x}", "", "aaaaaaaa-0000-0000-0000-000000000001"} {
		if validBCDGUID(g) {
			t.Errorf("%q accepted as an entry GUID", g)
		}
	}
	if !validBCDGUID("{aaaaaaaa-0000-0000-0000-000000000001}") {
		t.Error("real GUID rejected")
	}
}
