//go:build !windows

package main

// trustedUefiAuthorities is Windows-only: reading the firmware's db variable
// goes through the SecureBoot PowerShell module. The dev stub reports
// "unknown" (not read), which gates nothing.
func trustedUefiAuthorities() ([]string, bool) { return nil, false }
