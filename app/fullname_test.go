package main

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// tests/unit/full-name.bats runs the same inputs through deploy.sh's
// sanitize_full_name and wootc-go-native's phase2_user_json; keep the two
// lists in step.
var fullNameVectors = []struct{ name, in, want string }{
	{"unicode name kept byte for byte", "Zoë O'Brien-Åberg", "Zoë O'Brien-Åberg"},
	{"E2E seed shape", "Zoë O'Brien-Åberg a1b2c3", "Zoë O'Brien-Åberg a1b2c3"},
	{"separators, quote, backslash and newline", "Ann: \"Bo\\b\", Jr.\nSmith", "Ann \"Bo\\b\" Jr. Smith"},
	{"non-Latin scripts and combining marks", "  山田 太郎\u3000José\u0301  ", "山田 太郎 José\u0301"},
	{"control characters dropped", "A\x00l\x07i\x1bc\x7fe\u0085B\u009fob", "Alice Bob"},
	{"tabs and CRLF collapse", "Mary\t\tJane\r\nDoe", "Mary Jane Doe"},
	{"a dropped separator between spaces leaves one space", "Li , Wei : Chen", "Li Wei Chen"},
	{"only separators", " :,\n\t ", ""},
	{"empty", "", ""},
	{"invalid UTF-8 dropped", "Ren\xffé", "René"},
	{"no-break and ideographic spaces", "O\u00a0Neil\u2003Smith", "O Neil Smith"},
}

func TestSanitizeFullName(t *testing.T) {
	for _, tc := range fullNameVectors {
		t.Run(tc.name, func(t *testing.T) {
			got := sanitizeFullName(tc.in)
			if got != tc.want {
				t.Fatalf("sanitizeFullName(%q) = %q, want %q", tc.in, got, tc.want)
			}
			if strings.ContainsAny(got, ":,\n\r") {
				t.Fatalf("sanitizeFullName(%q) = %q still holds a GECOS separator or newline", tc.in, got)
			}
		})
	}
}

func TestSanitizeFullNameCapsAtACharacterBoundary(t *testing.T) {
	// 255 ASCII bytes then a 2-byte 'é': the cap must not split the 'é'.
	in := strings.Repeat("a", 255) + "é" + "tail"
	got := sanitizeFullName(in)
	if got != strings.Repeat("a", 255) {
		t.Fatalf("got %d bytes %q", len(got), got)
	}
	// A cut that lands right after a space must not leave it trailing.
	in = strings.Repeat("b", 255) + " c"
	if got := sanitizeFullName(in); got != strings.Repeat("b", 255) {
		t.Fatalf("got %q", got)
	}
	long := sanitizeFullName(strings.Repeat("Åberg ", 100))
	if len(long) > maxFullNameBytes || !utf8.ValidString(long) || strings.HasSuffix(long, " ") {
		t.Fatalf("long name not capped cleanly: %d bytes %q", len(long), long)
	}
}
