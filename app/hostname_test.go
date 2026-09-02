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

// #197 / #225: Under over-the-shoulder UAC, user.Current() is the elevating
// admin. deriveHumanUsername must derive the machine's human user rather than
// the admin, preferring explicit elevation-boundary environment variables, then
// the interactive desktop session owner (Win32_ComputerSystem.UserName /
// explorer.exe process owner), falling back to the current process user.
func TestDeriveHumanUsernameUAC(t *testing.T) {
	cases := []struct {
		name            string
		envUser         string
		interactiveUser string
		currentUser     string
		want            string
	}{
		{
			name:            "standard UAC: interactive human preferred over elevating admin",
			envUser:         "",
			interactiveUser: `CORP\Alice`,
			currentUser:     `LocalAdmin`,
			want:            "alice",
		},
		{
			name:            "elevation environment variable takes highest precedence",
			envUser:         "Bob Smith",
			interactiveUser: `CORP\Alice`,
			currentUser:     `LocalAdmin`,
			want:            "bob-smith",
		},
		{
			name:            "fallback to current user when interactive user is unavailable",
			envUser:         "",
			interactiveUser: "",
			currentUser:     `LocalAdmin`,
			want:            "localadmin",
		},
		{
			name:            "fallback to winuser when all signals are empty or invalid",
			envUser:         "",
			interactiveUser: "",
			currentUser:     "",
			want:            "winuser",
		},
		{
			name:            "interactive user with domain stripped",
			envUser:         "",
			interactiveUser: `WORKGROUP\charlie`,
			currentUser:     `Administrator`,
			want:            "charlie",
		},
		{
			name:            "interactive user with email/AzureAD stripped",
			envUser:         "",
			interactiveUser: `MicrosoftAccount\dana@example.com`,
			currentUser:     `LocalAdmin`,
			want:            "dana",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := deriveHumanUsername(tc.envUser, tc.interactiveUser, tc.currentUser)
			if got != tc.want {
				t.Errorf("deriveHumanUsername(%q, %q, %q) = %q, want %q",
					tc.envUser, tc.interactiveUser, tc.currentUser, got, tc.want)
			}
		})
	}
}

// #197 / #225: dedicatedVolumeInfo and removePartitionAndExtendC must require
// the "wootc-data" volume label before claiming ownership of a partition. An
// empty personal partition without the label must return false so RemovePartition
// is never offered and user data cannot be destroyed.
func TestDedicatedVolumeLabelGate(t *testing.T) {
	cases := []struct {
		name       string
		itemsCount int
		label      string
		want       bool
	}{
		{
			name:       "valid wootc partition with exact label and 0 extra items",
			itemsCount: 0,
			label:      "wootc-data",
			want:       true,
		},
		{
			name:       "case-insensitive label matching",
			itemsCount: 0,
			label:      "WOOTC-DATA",
			want:       true,
		},
		{
			name:       "label with surrounding whitespace",
			itemsCount: 0,
			label:      "  wootc-data  ",
			want:       true,
		},
		{
			name:       "empty personal partition without label must not be claimed",
			itemsCount: 0,
			label:      "",
			want:       false,
		},
		{
			name:       "empty personal partition with user label must not be claimed",
			itemsCount: 0,
			label:      "Personal",
			want:       false,
		},
		{
			name:       "empty partition labeled Data must not be claimed",
			itemsCount: 0,
			label:      "Data",
			want:       false,
		},
		{
			name:       "partition with wootc-data label but extraneous files must not be claimed",
			itemsCount: 1,
			label:      "wootc-data",
			want:       false,
		},
		{
			name:       "partition with wrong label and files must not be claimed",
			itemsCount: 3,
			label:      "Backup",
			want:       false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := isDedicatedVolume(tc.itemsCount, tc.label)
			if got != tc.want {
				t.Errorf("isDedicatedVolume(%d, %q) = %v, want %v",
					tc.itemsCount, tc.label, got, tc.want)
			}
		})
	}
}
