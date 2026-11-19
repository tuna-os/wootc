package main

import (
	"fmt"
	"strconv"
	"strings"
)

// normalizeBitLockerRecoveryPassword accepts the two staging representations,
// validates BitLocker's group checksums, and returns cryptsetup's canonical form.
// Errors never include recovery-key material.
func normalizeBitLockerRecoveryPassword(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if len(raw) == 55 {
		for i := 6; i < 55; i += 7 {
			if raw[i] != '-' {
				return "", fmt.Errorf("invalid BitLocker recovery password format")
			}
		}
		raw = strings.ReplaceAll(raw, "-", "")
	}
	if len(raw) != 48 {
		return "", fmt.Errorf("invalid BitLocker recovery password length")
	}
	groups := make([]string, 0, 8)
	for i := 0; i < 48; i += 6 {
		group := raw[i : i+6]
		for _, digit := range group {
			if digit < '0' || digit > '9' {
				return "", fmt.Errorf("invalid BitLocker recovery password digits")
			}
		}
		value, err := strconv.Atoi(group)
		if err != nil || value%11 != 0 || value/11 > 65535 {
			return "", fmt.Errorf("invalid BitLocker recovery password checksum")
		}
		groups = append(groups, group)
	}
	return strings.Join(groups, "-"), nil
}
