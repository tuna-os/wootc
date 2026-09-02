package main

import "testing"

// Uninstall restoration (#238, v1.0 criterion 2). "One uninstall puts
// everything back" includes hibernation and Fast Startup, which the install
// turns off — so the pre-install values have to be read back exactly, and
// "never recorded" has to be distinguishable from "was off".

func TestParsePriorPower(t *testing.T) {
	for _, tc := range []struct {
		name                 string
		content              string
		hibernate, hiberboot string
	}{
		{"both on", "hibernate=1\nhiberboot=1\n", "1", "1"},
		{"both off", "hibernate=0\nhiberboot=0\n", "0", "0"},
		{"mixed", "hibernate=1\nhiberboot=0\n", "1", "0"},
		{"crlf", "hibernate=1\r\nhiberboot=1\r\n", "1", "1"},
		{"whitespace", "  hibernate = 1 \n hiberboot=0\n", "1", "0"},
		{"empty file", "", "", ""},
		// The installer writes empty values when it could not read the
		// registry. That is "unknown", not "was off" — restoring a machine to
		// 0 because we failed to look is exactly the silent change uninstall
		// promises not to make.
		{"unreadable at install time", "hibernate=\nhiberboot=\n", "", ""},
		{"partial record", "hibernate=1\n", "1", ""},
		{"unknown keys ignored", "colour=blue\nhibernate=1\n", "1", ""},
		{"no separator", "hibernate\n", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			hib, hbb := parsePriorPower(tc.content)
			if hib != tc.hibernate || hbb != tc.hiberboot {
				t.Errorf("parsePriorPower(%q) = (%q, %q), want (%q, %q)",
					tc.content, hib, hbb, tc.hibernate, tc.hiberboot)
			}
		})
	}
}

// The old reader was strings.Contains(content, "hibernate=1"), which cannot
// tell 1 from 10 and would re-enable hibernation on a machine whose recorded
// value was neither.
func TestParsePriorPower_DoesNotSubstringMatch(t *testing.T) {
	hib, _ := parsePriorPower("hibernate=10\nhiberboot=0\n")
	if hib == "1" {
		t.Errorf("hibernate=10 must not read as 1 (got %q)", hib)
	}
	if hib != "10" {
		t.Errorf("hibernate = %q, want the recorded value 10", hib)
	}
}

// A value that was OFF before the install must stay off. restorePriorPowerState
// only ever re-enables, so this pins the input side of that: only an exact "1"
// may trigger a restore.
func TestParsePriorPower_OnlyExactOneMeansRestore(t *testing.T) {
	for _, content := range []string{
		"hibernate=0\nhiberboot=0\n",
		"hibernate=\nhiberboot=\n",
		"",
		"hibernate=true\nhiberboot=yes\n",
	} {
		hib, hbb := parsePriorPower(content)
		if hib == "1" || hbb == "1" {
			t.Errorf("parsePriorPower(%q) = (%q, %q) — must not ask for a restore", content, hib, hbb)
		}
	}
}
