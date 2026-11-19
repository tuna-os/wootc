//go:build !windows

package main

import (
	"os"
	"testing"
)

func openScrubObservation(t *testing.T, path string) *os.File {
	t.Helper()
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	return file
}
