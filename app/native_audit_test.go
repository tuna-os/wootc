package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestNativeAuditRefusesPartialTreeAndPreservesBytes(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "public-marker")
	data := []byte("unchanged")
	if err := os.WriteFile(file, data, 0600); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(file)
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	inspect := func(string) error { calls++; return nil }
	if err := auditNativeStatusTree(context.Background(), root, 1, inspect); err == nil || calls != 1 {
		t.Fatalf("partial audit accepted: %v %d", err, calls)
	}
	calls = 0
	if err := auditNativeStatusTree(context.Background(), root, 2, inspect); err != nil || calls != 2 {
		t.Fatalf("full audit refused: %v %d", err, calls)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	calls = 0
	if err := auditNativeStatusTree(ctx, root, 2, inspect); err == nil || calls != 0 {
		t.Fatalf("canceled audit ran: %v %d", err, calls)
	}
	after, err := os.Stat(file)
	if err != nil {
		t.Fatal(err)
	}
	observed, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	if string(observed) != string(data) || before.Mode() != after.Mode() || !before.ModTime().Equal(after.ModTime()) {
		t.Fatal("read-only audit modified marker")
	}
}
