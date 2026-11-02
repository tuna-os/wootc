package main

import "testing"

func TestProfileAccountPlanRejectsInvalidPrimaryBeforeDiscovery(t *testing.T) {
	app := &App{}
	for _, primary := range []string{"", "root", "nobody", "Alice", "1alice", "alice/path", "alice\tother"} {
		if _, err := app.GetProfileAccountPlan(primary); err == nil {
			t.Fatalf("profile plan accepted invalid primary %q", primary)
		}
	}
}
