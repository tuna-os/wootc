//go:build !windows

package main

// The Linux build does not inspect a Windows installation.
func verifyReportedLinuxHealth() error { return nil }
