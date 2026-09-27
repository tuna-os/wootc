package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestInvalidInputLeavesPreviousRecord(t *testing.T) {
	dir := t.TempDir()
	template := filepath.Join(dir, "template")
	target := filepath.Join(dir, "state.json")
	if err := os.WriteFile(template, []byte("template"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, []byte("previous"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, data := range [][]byte{nil, bytes.Repeat([]byte("x"), maxMetadata+1)} {
		if writeMetadata(template, target, bytes.NewReader(data)) == nil {
			t.Fatal("invalid record accepted")
		}
		got, err := os.ReadFile(target)
		if err != nil || string(got) != "previous" {
			t.Fatalf("previous record changed: %s %v", got, err)
		}
	}
	if err := writeMetadata(template, target, bytes.NewBufferString("valid bounded payload")); err == nil {
		t.Fatal("filesystem without Windows descriptor accepted")
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 2 {
		t.Fatal("failed writer left a temporary file")
	}
}
