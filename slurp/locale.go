package slurp

import "strings"

// XKBFromLanguageTag maps a Windows BCP-47 UI language tag (e.g. "en-US",
// "pt-BR", "en-GB") to an XKB layout code. Region-specific keyboards win
// over the bare language default; unmapped tags return "" (skipped, so the
// distro default stays). A full KLID→XKB table is future work.
func XKBFromLanguageTag(tag string) string {
	t := strings.ToLower(tag)
	// Region overrides first.
	switch t {
	case "en-gb":
		return "gb"
	case "pt-br":
		return "br"
	case "en-us", "en-ca":
		return "us"
	case "fr-ca":
		return "ca"
	case "de-ch", "fr-ch":
		return "ch"
	case "es-es":
		return "es"
	case "es-mx", "es-us", "es-ar", "es-co", "es-cl":
		return "latam"
	}
	lang := t
	if i := strings.IndexByte(t, '-'); i > 0 {
		lang = t[:i]
	}
	return xkbByLanguage[lang]
}

var xkbByLanguage = map[string]string{
	"en": "us", "de": "de", "fr": "fr", "es": "es", "it": "it",
	"pt": "pt", "ru": "ru", "uk": "ua", "pl": "pl", "nl": "nl",
	"sv": "se", "no": "no", "nb": "no", "da": "dk", "fi": "fi",
	"cs": "cz", "sk": "sk", "hu": "hu", "ro": "ro", "el": "gr",
	"tr": "tr", "he": "il", "ar": "ara", "fa": "ir", "th": "th",
	"ja": "jp", "ko": "kr", "zh": "cn", "hi": "in", "vi": "vn",
	"id": "us", "sr": "rs", "hr": "hr", "bg": "bg", "lt": "lt",
	"lv": "lv", "et": "ee", "sl": "si", "is": "is",
}

// IANAFromWindowsZone maps a Windows time zone ID ("Pacific Standard Time")
// to an IANA zone. Only the common cases are mapped; ok is false for the
// rest, which the target skips (a full CLDR table is future work).
func IANAFromWindowsZone(id string) (zone string, ok bool) {
	zone, ok = windowsToIANA[id]
	return zone, ok
}

var windowsToIANA = map[string]string{
	"Pacific Standard Time":           "America/Los_Angeles",
	"Mountain Standard Time":          "America/Denver",
	"Central Standard Time":           "America/Chicago",
	"Eastern Standard Time":           "America/New_York",
	"Atlantic Standard Time":          "America/Halifax",
	"GMT Standard Time":               "Europe/London",
	"W. Europe Standard Time":         "Europe/Berlin",
	"Romance Standard Time":           "Europe/Paris",
	"Central Europe Standard Time":    "Europe/Warsaw",
	"E. Europe Standard Time":         "Europe/Bucharest",
	"Russian Standard Time":           "Europe/Moscow",
	"Turkey Standard Time":            "Europe/Istanbul",
	"Israel Standard Time":            "Asia/Jerusalem",
	"Arabian Standard Time":           "Asia/Dubai",
	"India Standard Time":             "Asia/Kolkata",
	"Bangladesh Standard Time":        "Asia/Dhaka",
	"SE Asia Standard Time":           "Asia/Bangkok",
	"China Standard Time":             "Asia/Shanghai",
	"Singapore Standard Time":         "Asia/Singapore",
	"Tokyo Standard Time":             "Asia/Tokyo",
	"Korea Standard Time":             "Asia/Seoul",
	"AUS Eastern Standard Time":       "Australia/Sydney",
	"New Zealand Standard Time":       "Pacific/Auckland",
	"Hawaiian Standard Time":          "Pacific/Honolulu",
	"Alaskan Standard Time":           "America/Anchorage",
	"US Mountain Standard Time":       "America/Phoenix",
	"Canada Central Standard Time":    "America/Regina",
	"SA Pacific Standard Time":        "America/Bogota",
	"E. South America Standard Time":  "America/Sao_Paulo",
	"Argentina Standard Time":         "America/Argentina/Buenos_Aires",
	"South Africa Standard Time":      "Africa/Johannesburg",
	"Egypt Standard Time":             "Africa/Cairo",
	"W. Central Africa Standard Time": "Africa/Lagos",
	"UTC":                             "Etc/UTC",
}
