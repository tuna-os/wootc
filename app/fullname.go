package main

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// maxFullNameBytes caps the account full name. 256 bytes is util-linux chfn's
// field limit, so a name wootc writes can still be edited with chfn later.
const maxFullNameBytes = 256

// sanitizeFullName turns the Windows account full name into the GECOS full
// name the deployer hands fisherman (vault key full_name → recipe
// user.fullname → useradd --comment). useradd refuses a comment containing ':'
// or a newline, and fisherman treats that refusal as fatal to the whole
// install, so this must never let one through. The rule, kept identical in
// payload/deployer/deploy.sh (sanitize_full_name) and
// payload/migration/wootc-go-native (phase2_user_json):
//
//   - every Unicode whitespace character (unicode.IsSpace, newlines included)
//     becomes a space;
//   - control characters (Unicode Cc), invalid UTF-8, ':' (the passwd field
//     separator) and ',' (the GECOS subfield separator: everything after it
//     reads as room/phone) are dropped;
//   - runs of spaces collapse to one, and the ends are trimmed;
//   - the result is cut to 256 bytes on a character boundary, then trimmed.
//
// Everything else, letters, marks and digits of any script, apostrophes,
// hyphens, periods, quotes, is kept byte for byte.
func sanitizeFullName(raw string) string {
	var b strings.Builder
	b.Grow(len(raw))
	space := false
	for i := 0; i < len(raw); {
		r, size := utf8.DecodeRuneInString(raw[i:])
		i += size
		switch {
		case r == utf8.RuneError && size == 1:
			continue
		case unicode.IsSpace(r):
			space = b.Len() > 0
			continue
		case unicode.Is(unicode.Cc, r), r == ':', r == ',':
			continue
		}
		if space {
			b.WriteByte(' ')
			space = false
		}
		b.WriteRune(r)
	}
	out := b.String()
	if len(out) > maxFullNameBytes {
		cut := maxFullNameBytes
		for cut > 0 && !utf8.RuneStart(out[cut]) {
			cut--
		}
		out = strings.TrimRight(out[:cut], " ")
	}
	return out
}
