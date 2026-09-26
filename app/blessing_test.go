package main

// Upstream blessings (#227): a branded build wears somebody else's mark, so
// every brand carries a written decision about whether that is allowed —
// app/branding/<brand>/blessing.json.
//
// These tests exist because "we should ask them" is not a state a repository
// can be in. Either the decision is recorded or the brand does not ship, and
// the invariant that matters most is the one that cannot be satisfied by
// wishing: a brand this project does not own may not be marked `blessed`
// without a link to the place somebody said yes.

import (
	"encoding/json"
	"strings"
	"testing"
)

type brandBlessing struct {
	Brand     string `json:"brand"`
	SelfOwned bool   `json:"selfOwned"`
	Status    string `json:"status"`
	Mark      struct {
		Owner       string `json:"owner"`
		AssetSource string `json:"assetSource"`
	} `json:"mark"`
	Decisions map[string]string `json:"decisions"`
	Winget    struct {
		Identifier       string `json:"identifier"`
		NamespaceOwner   string `json:"namespaceOwner"`
		IdentifierAgreed bool   `json:"identifierAgreed"`
	} `json:"winget"`
	Ask struct {
		Filed     bool     `json:"filed"`
		Venue     string   `json:"venue"`
		Shown     []string `json:"shown"`
		OpenedAt  string   `json:"openedAt"`
		DecidedAt string   `json:"decidedAt"`
		Evidence  string   `json:"evidence"`
	} `json:"ask"`
	Notes string `json:"notes"`
}

// The four things each project is asked to grant, per #227: the mark, the
// name, the tagline, and distributing an exe under their brand.
var blessingQuestions = []string{"mark", "name", "tagline", "distributeExe"}

func loadBlessings(t *testing.T) map[string]brandBlessing {
	t.Helper()
	entries, err := brandFS.ReadDir("branding")
	if err != nil {
		t.Fatalf("read embedded branding dir: %v", err)
	}
	out := map[string]brandBlessing{}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		id := e.Name()
		data, err := brandFS.ReadFile("branding/" + id + "/blessing.json")
		if err != nil {
			t.Errorf("brand %s: no blessing.json — a brand ships only with a recorded decision (#227)", id)
			continue
		}
		var b brandBlessing
		if err := json.Unmarshal(data, &b); err != nil {
			t.Errorf("brand %s: unparseable blessing.json: %v", id, err)
			continue
		}
		out[id] = b
	}
	if len(out) == 0 {
		t.Fatal("no blessing records found at all")
	}
	return out
}

// derivedStatus is the ONLY source of a brand's status: it falls out of the
// four answers. A hand-written status that disagrees with them is how a
// record starts lying — someone edits `mark: no` and forgets the header.
func derivedStatus(d map[string]string) string {
	all := true
	for _, q := range blessingQuestions {
		switch d[q] {
		case "no":
			return "declined"
		case "yes":
		default:
			all = false
		}
	}
	if all {
		return "blessed"
	}
	return "pending"
}

func TestBrandBlessings_RecordedAndWellFormed(t *testing.T) {
	for id, b := range loadBlessings(t) {
		if b.Brand != id {
			t.Errorf("brand %s: record names brand %q", id, b.Brand)
		}
		if b.Mark.Owner == "" {
			t.Errorf("brand %s: no mark.owner — the record must name who is being asked", id)
		}
		switch b.Status {
		case "blessed", "pending", "declined":
		default:
			t.Errorf("brand %s: status %q is not blessed/pending/declined", id, b.Status)
		}
		for _, q := range blessingQuestions {
			switch b.Decisions[q] {
			case "yes", "no", "pending":
			default:
				t.Errorf("brand %s: decision %q is %q, want yes/no/pending", id, q, b.Decisions[q])
			}
		}
		if len(b.Decisions) != len(blessingQuestions) {
			t.Errorf("brand %s: %d decisions recorded, want exactly %v",
				id, len(b.Decisions), blessingQuestions)
		}
		if want := derivedStatus(b.Decisions); b.Status != want {
			t.Errorf("brand %s: status %q disagrees with its own answers %v (want %q)",
				id, b.Status, b.Decisions, want)
		}
		if b.Notes == "" {
			t.Errorf("brand %s: no notes — a bare status cannot say what was actually asked", id)
		}
	}
}

// The anti-presumption gate. Marking someone else's brand `blessed` is a claim
// about a conversation that happened; it must point at that conversation.
func TestBrandBlessings_ForeignMarksNeedEvidence(t *testing.T) {
	for id, b := range loadBlessings(t) {
		if b.SelfOwned {
			continue
		}
		if b.Status == "blessed" && b.Ask.Evidence == "" {
			t.Errorf("brand %s: blessed with no ask.evidence — a yes we cannot link to is a yes we invented", id)
		}
		if b.Status == "declined" && b.Ask.Evidence == "" {
			t.Errorf("brand %s: declined with no ask.evidence — dropping an exe needs the same proof as shipping one", id)
		}
		if b.Status != "pending" && !b.Ask.Filed {
			t.Errorf("brand %s: status %q but ask.filed is false — nobody was asked", id, b.Status)
		}
		if b.Ask.Venue == "" {
			t.Errorf("brand %s: no ask.venue — 'ask them' is not actionable without a where", id)
		}
		if b.Ask.Filed && b.Ask.OpenedAt == "" {
			t.Errorf("brand %s: ask.filed with no openedAt — an ask with no date cannot be chased", id)
		}
		if b.Status != "pending" && b.Ask.DecidedAt == "" {
			t.Errorf("brand %s: decided (%s) with no decidedAt", id, b.Status)
		}
	}
}

// Self-owned is a claim too, and the cheapest one to get wrong: it is the
// escape hatch from every check above.
func brandOwnershipPolicy(t *testing.T) (map[string]bool, map[string]bool) {
	t.Helper()
	data, err := brandFS.ReadFile("branding/ownership.json")
	if err != nil {
		t.Fatal(err)
	}
	var policy struct {
		SelfOwnedBrands  []string `json:"selfOwnedBrands"`
		WingetNamespaces []string `json:"wingetNamespaces"`
	}
	if err := json.Unmarshal(data, &policy); err != nil {
		t.Fatal(err)
	}
	ours, namespaces := map[string]bool{}, map[string]bool{}
	for _, id := range policy.SelfOwnedBrands {
		ours[id] = true
	}
	for _, namespace := range policy.WingetNamespaces {
		namespaces[namespace] = true
	}
	return ours, namespaces
}

func TestBrandBlessings_SelfOwnedIsOnlyOurOwnMarks(t *testing.T) {
	ours, _ := brandOwnershipPolicy(t)
	for id, b := range loadBlessings(t) {
		if b.SelfOwned && !ours[id] {
			t.Errorf("brand %s: claims selfOwned, but only %v are this project's marks", id, ours)
		}
		if !b.SelfOwned && ours[id] {
			t.Errorf("brand %s: is one of this project's own marks but is not selfOwned", id)
		}
	}
}

// winget identifiers live in a namespace, and the namespace belongs to whoever
// owns the brand: `Bazzite.Installer` is Universal Blue's to grant, not ours
// to take (#227 (3)).
func TestBrandBlessings_WingetNamespaceFollowsTheMark(t *testing.T) {
	_, namespaces := brandOwnershipPolicy(t)
	for id, b := range loadBlessings(t) {
		if b.Winget.Identifier == "" {
			t.Errorf("brand %s: no winget.identifier proposed", id)
			continue
		}
		if !strings.Contains(b.Winget.Identifier, ".") {
			t.Errorf("brand %s: winget identifier %q is not Publisher.Package", id, b.Winget.Identifier)
		}
		if b.Winget.NamespaceOwner == "" {
			t.Errorf("brand %s: winget.namespaceOwner unrecorded — who owns %q?", id, b.Winget.Identifier)
		}
		// An identifier we have not been granted must not be marked agreed,
		// and a foreign namespace cannot be agreed without a recorded yes.
		if b.Winget.IdentifierAgreed && !b.SelfOwned && b.Ask.Evidence == "" {
			t.Errorf("brand %s: winget identifier %q marked agreed with no evidence", id, b.Winget.Identifier)
		}
		if b.SelfOwned && !namespaces[strings.SplitN(b.Winget.Identifier, ".", 2)[0]] {
			t.Errorf("brand %s: self-owned but its identifier %q is outside our namespace", id, b.Winget.Identifier)
		}
	}
}

// The README is where a human reads the outcome (#227 (4)). It drifts the
// moment it is not checked, and a stale "blessed" row is worse than none.
func TestBrandBlessings_READMETableMatchesTheRecords(t *testing.T) {
	data, err := brandFS.ReadFile("branding/README.md")
	if err != nil {
		t.Fatalf("read branding README: %v", err)
	}
	readme := string(data)
	for id, b := range loadBlessings(t) {
		var row string
		for _, line := range strings.Split(readme, "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "| `"+id+"`") {
				row = line
				break
			}
		}
		if row == "" {
			t.Errorf("brand %s: no row in app/branding/README.md — the outcome is unrecorded where humans look", id)
			continue
		}
		// Compare CELLS, not the row as a whole. Substring matching passes a
		// row whose status has drifted to "blessed" as long as any decision
		// cell still reads "pending" — which is exactly the drift that
		// matters, and it slipped through until this was tightened.
		cells := strings.Split(row, "|")
		// | brand | owner | status | mark | name | tagline | exe | winget |
		if len(cells) < 10 {
			t.Errorf("brand %s: README row has %d cells, want the 8-column table:\n  %s",
				id, len(cells)-2, row)
			continue
		}
		cell := func(i int) string { return strings.TrimSpace(cells[i]) }
		if cell(3) != b.Status {
			t.Errorf("brand %s: README status cell is %q, record says %q", id, cell(3), b.Status)
		}
		for i, q := range blessingQuestions {
			if got, want := cell(4+i), b.Decisions[q]; got != want {
				t.Errorf("brand %s: README %s cell is %q, record says %q", id, q, got, want)
			}
		}
		if want := "`" + b.Winget.Identifier + "`"; cell(8) != want {
			t.Errorf("brand %s: README winget cell is %q, record says %q", id, cell(8), want)
		}
	}
}

func TestDerivedStatus(t *testing.T) {
	yes := map[string]string{"mark": "yes", "name": "yes", "tagline": "yes", "distributeExe": "yes"}
	if got := derivedStatus(yes); got != "blessed" {
		t.Errorf("all yes → %q, want blessed", got)
	}
	for _, q := range blessingQuestions {
		d := map[string]string{}
		for k, v := range yes {
			d[k] = v
		}
		d[q] = "no"
		if got := derivedStatus(d); got != "declined" {
			t.Errorf("%s=no → %q, want declined", q, got)
		}
		d[q] = "pending"
		if got := derivedStatus(d); got != "pending" {
			t.Errorf("%s=pending → %q, want pending", q, got)
		}
	}
	// A single no outranks three yeses: any one refusal is a refusal.
	mixed := map[string]string{"mark": "yes", "name": "yes", "tagline": "pending", "distributeExe": "no"}
	if got := derivedStatus(mixed); got != "declined" {
		t.Errorf("mixed with a no → %q, want declined", got)
	}
	if got := derivedStatus(nil); got != "pending" {
		t.Errorf("empty → %q, want pending", got)
	}
}
