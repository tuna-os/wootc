//go:build linux

package slurp

import "testing"

func TestStatfsAvailable(t *testing.T) {
	if n, err := statfsAvailable(t.TempDir()); err != nil || n < 0 {
		t.Errorf("statfsAvailable(tempdir) = %d, %v", n, err)
	}
	if _, err := statfsAvailable("/nonexistent/slurp/path"); err == nil {
		t.Error("statfsAvailable on a missing path: want an error")
	}
}
