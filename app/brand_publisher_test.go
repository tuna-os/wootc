package main

// Who the exe says made it. The version resource's CompanyName and the
// Add/Remove entry's Publisher are a claim of authorship. A branded build of
// somebody else's mark may name that somebody only after they have said yes
// (blessing.json status "blessed", #227); until then the publisher is the
// project that actually builds and ships the exe — ownership.json's
// distributor. packaging/brand.py effective_identity holds the same rule for
// the exe's version resource and the winget manifests
// (tests/unit/test_windows_resources.py, tests/unit/test_winget_brand.py).

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// asBrandBuild makes this test binary behave like the -X main.brandID=<id>
// exe, with the runtime overlays that would mask the embedded brand cleared.
func asBrandBuild(t *testing.T, id string) {
	t.Helper()
	old := brandID
	brandID = id
	t.Cleanup(func() { brandID = old })
	for _, name := range []string{"brand.json", "brand.css", "images.json", "channel.txt"} {
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

func embeddedBrandJSON(t *testing.T, id string) Branding {
	t.Helper()
	data, err := brandFS.ReadFile("branding/" + id + "/brand.json")
	if err != nil {
		t.Fatal(err)
	}
	var b Branding
	if err := json.Unmarshal(data, &b); err != nil {
		t.Fatal(err)
	}
	return b
}

// The guard itself: walk every brand in the checkout. A brand this project
// does not own, whose owner has not said yes, must name the distributor —
// never the owner — as publisher, and carry no copyright in the owner's name.
func TestUnblessedBrandsNeverClaimTheOwnerAsPublisher(t *testing.T) {
	policy, ok := brandOwnership()
	if !ok || policy.Distributor == "" {
		t.Fatal("app/branding/ownership.json names no distributor; an unblessed exe would have nobody to name")
	}
	unblessed := 0
	for id, record := range loadBlessings(t) {
		asBrandBuild(t, id)
		got := effectiveBranding()
		declared := embeddedBrandJSON(t, id)
		owner := strings.TrimSpace(strings.SplitN(record.Mark.Owner, "—", 2)[0])
		if record.SelfOwned {
			if got.Publisher != declared.Publisher && declared.Publisher != "" {
				t.Errorf("brand %s: self-owned, but publisher %q replaced its own %q", id, got.Publisher, declared.Publisher)
			}
			continue
		}
		if record.Status == "blessed" {
			continue
		}
		unblessed++
		if got.Publisher != policy.Distributor {
			t.Errorf("brand %s: status %q, but the exe names %q as publisher; until %s says yes it must be %q",
				id, record.Status, got.Publisher, owner, policy.Distributor)
		}
		if owner != "" && strings.Contains(got.Publisher+" "+got.Copyright, owner) {
			t.Errorf("brand %s: unblessed build claims %s in publisher %q / copyright %q", id, owner, got.Publisher, got.Copyright)
		}
		if strings.EqualFold(got.Publisher, got.Name) {
			t.Errorf("brand %s: publisher %q is the brand's own name", id, got.Publisher)
		}
	}
	if unblessed == 0 {
		t.Log("no unblessed foreign brand in this checkout; the rule above had nothing to hold")
	}
}

// The distributor is the generic build's own publisher: the project that
// builds every exe is the one wootc.exe already names.
func TestDistributorIsTheGenericBuildsPublisher(t *testing.T) {
	policy, _ := brandOwnership()
	if generic := embeddedBrandJSON(t, "wootc").Publisher; policy.Distributor != generic {
		t.Errorf("ownership.json distributor %q, generic brand publisher %q", policy.Distributor, generic)
	}
}

// The switch, both ways, on records the checkout may not hold yet: the owner
// is named only for a blessed record (or our own mark), and every other
// shape — pending, declined, wrong brand, unparsable, a selfOwned claim the
// policy does not back — fails closed.
func TestOwnerMayBeNamed(t *testing.T) {
	policy := brandOwnershipPolicyFile{SelfOwnedBrands: []string{"wootc"}, Distributor: "TunaOS"}
	cases := []struct {
		id, record string
		want       bool
	}{
		{"bazzite", `{"brand":"bazzite","status":"blessed"}`, true},
		{"bazzite", `{"brand":"bazzite","status":"pending"}`, false},
		{"bazzite", `{"brand":"bazzite","status":"declined"}`, false},
		{"bazzite", `{"brand":"bazzite","status":""}`, false},
		{"bazzite", `{"brand":"aurora","status":"blessed"}`, false},
		{"bazzite", `{"brand":"bazzite","selfOwned":true,"status":"blessed"}`, false},
		{"bazzite", `not json`, false},
		{"wootc", `{"brand":"wootc","selfOwned":true,"status":"blessed"}`, true},
	}
	for _, c := range cases {
		if got := ownerMayBeNamed(c.id, []byte(c.record), policy); got != c.want {
			t.Errorf("ownerMayBeNamed(%s, %s) = %v, want %v", c.id, c.record, got, c.want)
		}
	}
}

// What a Bazzite user sees in Apps & features today: Bazzite as the name,
// TunaOS as the publisher — not Universal Blue, who has not been asked.
func TestBazziteBuild_PublisherIsTheDistributorWhileUnblessed(t *testing.T) {
	asBrandBuild(t, "bazzite")
	b := effectiveBranding()
	if b.Publisher != "TunaOS" {
		t.Errorf("bazzite publisher = %q, want TunaOS while blessing.json is pending", b.Publisher)
	}
	if uninstallDisplayName(b) != "Bazzite" {
		t.Errorf("Add/Remove name = %q, want Bazzite", uninstallDisplayName(b))
	}
}
