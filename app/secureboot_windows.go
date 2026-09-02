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
// An empty result means "could not tell", never "trusts nothing": the caller
// warns rather than refusing.
func trustedUefiAuthorities() []string {
	out, err := runPowerShellOutput(
		`try { $v = Get-SecureBootUEFI -Name db -ErrorAction Stop; ` +
			`[Convert]::ToBase64String($v.Bytes) } catch { '' }`)
	if err == nil {
		if raw := strings.TrimSpace(out); raw != "" {
			if db, decErr := base64.StdEncoding.DecodeString(raw); decErr == nil {
				if gens := parseUEFISignatureListCAs(db); len(gens) > 0 {
					return gens
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
		return nil
	}
	seen := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		for _, gen := range matchMicrosoftUefiCA(line) {
			seen[gen] = true
		}
	}
	return sortedKeys(seen)
}
