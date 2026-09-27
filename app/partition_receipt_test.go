package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testPartitionReceipt() StoragePartitionReceipt {
	return StoragePartitionReceipt{1, "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222", "33333333-3333-3333-3333-333333333333", "22222222-2222-2222-2222-222222222222", 1000, "2026-09-27T00:00:00Z"}
}
func TestPartitionReceiptRequiresStableIdentity(t *testing.T) {
	tests := map[string]func(*StoragePartitionReceipt){"schema": func(r *StoragePartitionReceipt) { r.SchemaVersion = 2 }, "size": func(r *StoragePartitionReceipt) { r.SizeBytes = 0 }, "timestamp": func(r *StoragePartitionReceipt) { r.CreatedAt = "yesterday" }, "invalid GUID": func(r *StoragePartitionReceipt) { r.PartitionGUID = "{anything}" }, "zero GUID": func(r *StoragePartitionReceipt) { r.DiskGUID = "00000000-0000-0000-0000-000000000000" }, "Windows target": func(r *StoragePartitionReceipt) { r.PartitionGUID = r.SourceCPartitionGUID }, "different disk": func(r *StoragePartitionReceipt) { r.SourceCDiskGUID = "44444444-4444-4444-4444-444444444444" }}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			r := testPartitionReceipt()
			mutate(&r)
			if r.validate() == nil {
				t.Fatal("unsafe receipt accepted")
			}
		})
	}
}
func TestPartitionReceiptRejectsMalformedRecords(t *testing.T) {
	data, _ := json.Marshal(testPartitionReceipt())
	for _, bad := range [][]byte{append(append([]byte{}, data...), []byte(" {}")...), []byte(strings.Repeat(" ", 4097)), []byte(strings.Replace(string(data), `"schemaVersion":1`, `"unknown":true,"schemaVersion":1`, 1)), []byte(`{}`)} {
		if _, err := decodeStoragePartitionReceipt(bad); err == nil {
			t.Fatal("malformed receipt accepted")
		}
	}
}
func TestPartitionReceiptPreservesExistingAuthority(t *testing.T) {
	path := filepath.Join(t.TempDir(), "creation.json")
	receipt := testPartitionReceipt()
	if err := persistNewStoragePartitionReceipt(path, receipt); err != nil {
		t.Fatal(err)
	}
	original, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	replacement := receipt
	replacement.PartitionGUID = "44444444-4444-4444-4444-444444444444"
	if err := persistNewStoragePartitionReceipt(path, replacement); err == nil {
		t.Fatal("existing ownership replaced")
	}
	actual, _ := os.ReadFile(path)
	if string(actual) != string(original) {
		t.Fatal("prior authority changed")
	}
	observed, err := decodeStoragePartitionReceipt(actual)
	if err != nil || observed != receipt {
		t.Fatalf("receipt roundtrip: %v", err)
	}
}
func TestPartitionReceiptDoesNotFollowExistingSymlink(t *testing.T) {
	dir := t.TempDir()
	foreign := filepath.Join(dir, "foreign")
	path := filepath.Join(dir, "creation.json")
	if err := os.WriteFile(foreign, []byte("foreign bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(foreign, path); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if err := persistNewStoragePartitionReceipt(path, testPartitionReceipt()); err == nil {
		t.Fatal("followed symlink")
	}
	actual, _ := os.ReadFile(foreign)
	if string(actual) != "foreign bytes" {
		t.Fatal("foreign target modified")
	}
}
