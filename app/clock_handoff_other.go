//go:build !windows

package main

// windowsClock: dev builds run on Linux/macOS, whose hardware clock is UTC.
func windowsClock() (rtcUniversal bool, ianaZone string) { return true, "" }
