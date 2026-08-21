//go:build !windows

package main

// systemPrefersDark is Windows-only in practice; see theme_windows.go. The
// non-Windows build exists so main.go stays compilable on Linux for the
// cross-platform `go test` tier, and returns the historical default.
func systemPrefersDark() bool { return true }
