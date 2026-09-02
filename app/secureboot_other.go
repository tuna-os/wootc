//go:build !windows

package main

// trustedUefiAuthorities is Windows-only: reading the firmware's db variable
// goes through the SecureBoot PowerShell module. The dev stub reports
// "unknown", which gates nothing.
func trustedUefiAuthorities() []string { return nil }
