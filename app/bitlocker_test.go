package main

import (
	"strings"
	"testing"
)

func TestNormalizeBitLockerRecoveryPassword(t *testing.T) {
	const canonical = "013574-062458-099132-038016-086790-025795-074679-720885"
	for _, input := range []string{canonical, strings.ReplaceAll(canonical, "-", ""), canonical + "\r\n"} {
		got, err := normalizeBitLockerRecoveryPassword(input)
		if err != nil || got != canonical {
			t.Fatalf("valid fixture did not canonicalize (length %d): %v", len(input), err)
		}
	}
	// Repetition is not a format error: 111111 / 11 = 10101, within
	// BitLocker's uint16 group domain. Entropy is not this parser's policy.
	if got, err := normalizeBitLockerRecoveryPassword(strings.Repeat("1", 48)); err != nil || got != strings.TrimSuffix(strings.Repeat("111111-", 8), "-") {
		t.Fatalf("valid repeated-digit groups refused: %v", err)
	}
	for _, input := range []string{
		"", strings.Repeat("9", 48), strings.Repeat("a", 48),
		strings.Replace(canonical, "013574", "013575", 1),
		strings.Replace(canonical, "720885", "720896", 1),
		strings.Replace(canonical, "-", "+", 1),
		canonical + "-", "fixture-secret=" + canonical,
	} {
		if _, err := normalizeBitLockerRecoveryPassword(input); err == nil {
			t.Fatal("invalid recovery-password fixture accepted")
		} else if input != "" && strings.Contains(err.Error(), input) {
			t.Fatal("recovery-password error disclosed secret input")
		}
	}
}
