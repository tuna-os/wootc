package main

import "testing"

// Windows computer names are far more permissive than Linux hostnames — most
// importantly they allow underscores, which systemd-hostnamed and a lot of
// other tooling reject. #174 copies the Windows name onto the migrated system,
// so the conversion has to be lossy in a *legal* direction rather than a
// straight copy.
func TestSanitizeHostname(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"already legal", "thinkpad", "thinkpad"},
		{"uppercase is lowercased", "DESKTOP-A1B2C3", "desktop-a1b2c3"},
		{"underscores become hyphens", "MY_HOME_PC", "my-home-pc"},
		{"spaces become hyphens", "James Laptop", "james-laptop"},
		{"dots become hyphens", "office.pc", "office-pc"},
		{"runs of separators collapse", "a___b   c...d", "a-b-c-d"},
		{"leading and trailing separators dropped", "_-pc-_", "pc"},
		{"illegal characters removed", "pc!@#$%^&*()name", "pcname"},
		{"surrounding whitespace trimmed", "  laptop  ", "laptop"},
		{"digits kept", "pc123", "pc123"},

		// Nothing usable survives -> "" so the GUI keeps its own default
		// instead of rendering an empty hostname field.
		{"empty input", "", ""},
		{"only separators", "___", ""},
		{"only illegal characters", "!!!", ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := sanitizeHostname(tc.in); got != tc.want {
				t.Errorf("sanitizeHostname(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

// RFC 1123 caps a hostname label at 63 characters. Truncation must not leave a
// trailing hyphen, which would itself be illegal.
func TestSanitizeHostnameLengthCap(t *testing.T) {
	long := ""
	for i := 0; i < 100; i++ {
		long += "a"
	}
	got := sanitizeHostname(long)
	if len(got) != 63 {
		t.Errorf("length = %d, want 63", len(got))
	}

	// 62 legal characters then separators: truncating at 63 would land on the
	// hyphen, so the trim has to run again after the cut.
	tail := ""
	for i := 0; i < 62; i++ {
		tail += "b"
	}
	got = sanitizeHostname(tail + "____________")
	if got != tail {
		t.Errorf("got %q, want %q (no trailing hyphen after truncation)", got, tail)
	}
}

// Windows account names are messy in ways Linux usernames cannot be: spaces
// and capitals are routine ("James Reilly"), and the name may arrive as
// DOMAIN\User or an AzureAD/Microsoft-account email. useradd additionally
// rejects a leading digit or hyphen and caps the name at 32 characters.
func TestSanitizeUsername(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"simple", "james", "james"},
		{"capitals lowered", "James", "james"},
		{"space becomes hyphen", "James Reilly", "james-reilly"},
		{"domain prefix stripped", `CORP\jreilly`, "jreilly"},
		{"forward slash prefix stripped", "MicrosoftAccount/jim", "jim"},
		{"email local part kept", "james@example.com", "james"},
		{"domain and email combined", `MicrosoftAccount\james@example.com`, "james"},
		{"underscore preserved", "my_user", "my_user"},
		{"dot becomes hyphen", "james.reilly", "james-reilly"},
		{"illegal characters dropped", "jam!es#", "james"},
		{"leading digits dropped", "123james", "james"},
		{"leading hyphen dropped", "-james", "james"},

		{"empty", "", ""},
		{"only digits", "12345", ""},
		{"only illegal", "!!!", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := sanitizeUsername(tc.in); got != tc.want {
				t.Errorf("sanitizeUsername(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestSanitizeUsernameLengthCap(t *testing.T) {
	long := ""
	for i := 0; i < 50; i++ {
		long += "a"
	}
	if got := sanitizeUsername(long); len(got) != 32 {
		t.Errorf("length = %d, want 32 (useradd limit)", len(got))
	}
}

// The bare-minimum launchpad contract: identity must ALWAYS derive, because a
// derived identity is what keeps the username/hostname fields under Advanced
// and the default form down to one password prompt. A profile named entirely
// in non-Latin script (routine on non-English Windows, #197) sanitises to ""
// — the suggestion layer must fall back, never come back empty.
func TestSuggestIdentityNeverEmpty(t *testing.T) {
	if got := suggestUsername("James Reilly"); got != "james-reilly" {
		t.Errorf("suggestUsername passthrough = %q", got)
	}
	if got := suggestUsername("田中"); got != "winuser" {
		t.Errorf("suggestUsername(non-Latin) = %q, want winuser", got)
	}
	if got := suggestUsername(""); got != "winuser" {
		t.Errorf("suggestUsername(empty) = %q, want winuser", got)
	}
	if got := suggestHostname("DESKTOP-A1B2C3"); got != "desktop-a1b2c3" {
		t.Errorf("suggestHostname passthrough = %q", got)
	}
	// Nothing usable: fall back to the distribution's own name (brand-aware),
	// so a branded install never boots calling itself something else.
	if got := suggestHostname("!!!"); got == "" {
		t.Error("suggestHostname must never return empty")
	}
	if got := suggestHostname(""); got != sanitizeHostname(effectiveBranding().Name) {
		t.Errorf("suggestHostname(empty) = %q, want the brand name", got)
	}
}
