//go:build windows

package main

import "testing"

// Read-only observation: neither ProgramData nor a receipt directory is created.
func TestPartitionReceiptProgramDataParents(t *testing.T) {
	dir, err := partitionReceiptDirectory()
	if err != nil {
		t.Fatal(err)
	}
	if err := inspectPartitionReceiptParents(dir); err != nil {
		t.Fatalf("actual ProgramData parent trust gate: %v", err)
	}
	t.Logf("readonly actual ProgramData parent trust accepted: %s", dir)
}
