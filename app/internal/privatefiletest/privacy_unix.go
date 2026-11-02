//go:build !windows

// Package privatefiletest provides platform-native confidentiality assertions.
package privatefiletest

import (
	"os"
	"testing"
)

func AssertPrivate(t *testing.T, path string) {
	t.Helper()
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !st.Mode().IsRegular() || st.Mode().Perm() != 0o600 {
		t.Fatalf("private file mode = %v, want regular 0600", st.Mode())
	}
}
