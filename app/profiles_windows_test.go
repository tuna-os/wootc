//go:build windows

package main

import (
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

func TestPrimaryProfileIgnoresEnvironment(t *testing.T) {
	profile, err := windows.GetCurrentProcessToken().GetUserProfileDirectory()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("USERPROFILE", `Z:\someone-else`)
	t.Setenv("WOOTC_ORIGINAL_USER", "another-admin")
	if got := primaryProfileDir(); got != filepath.Base(profile) {
		t.Fatalf("profile came from environment rather than token: %q", got)
	}
}
