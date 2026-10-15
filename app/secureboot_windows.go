//go:build windows

package main

import (
	"encoding/base64"
	"strings"
)

// trustedUefiAuthorities reads the firmware's `db` variable and reports which
// Microsoft UEFI CA generations it holds (#322).
//
// Get-SecureBootUEFI returns the raw EFI_SIGNATURE_LIST chain, which is the
// authoritative form; it is base64'd across the process boundary because
// runCmd hands back text. Get-SecureBootDbCertificates exists on newer
// builds and is tried second — it returns parsed certificates, so it needs
// no signature-list walk, only the subject strings.
//
// The second result says whether db was actually read: true only when a
// source returned at least one certificate. An empty generation list with
// read=false means "could not tell" and warns; with read=true it means the
// firmware holds neither third-party CA, and the caller refuses.
func trustedUefiAuthorities() ([]string, bool) {
	out, err := runPowerShellOutput(
		`try { $v = Get-SecureBootUEFI -Name db -ErrorAction Stop; ` +
			`[Convert]::ToBase64String($v.Bytes) } catch { '' }`)
	if err == nil {
		if raw := strings.TrimSpace(out); raw != "" {
			if db, decErr := base64.StdEncoding.DecodeString(raw); decErr == nil {
				if gens, certs := parseUEFIDb(db); certs > 0 {
					return gens, true
				}
			}
		}
	}

	// Fallback: the cmdlet that hands back parsed certificates. Present on
	// Windows 11 and recent Windows 10; absent elsewhere, which is exactly
	// the case the warn path exists for.
	out, err = runPowerShellOutput(
		`try { Get-SecureBootDbCertificates -ErrorAction Stop | ` +
			`ForEach-Object { $_.Subject } } catch { '' }`)
	if err != nil {
		return nil, false
	}
	seen := map[string]bool{}
	subjects := 0
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		subjects++
		for _, gen := range matchMicrosoftUefiCA(line) {
			seen[gen] = true
		}
	}
	return sortedKeys(seen), subjects > 0
}
