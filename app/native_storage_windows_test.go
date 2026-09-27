//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNativeConfigurationStorageReobservesSameLetterPhysicalIdentity(t *testing.T) {
	for _, change := range []string{"none", "disk", "partition", "serial", "protection", "query", "metadata"} {
		t.Run(change, func(t *testing.T) {
			row := nativeStorageRow{DriveLetter: "F", DiskGUID: "{11111111-1111-1111-1111-111111111111}", PartitionGUID: "{22222222-2222-2222-2222-222222222222}", VolumeStatus: "FullyDecrypted", ProtectionStatus: "Off"}
			mutated := false
			queryCalls, serialCalls := 0, 0
			query := func(context.Context) ([]nativeStorageRow, error) {
				queryCalls++
				if mutated {
					switch change {
					case "disk":
						row.DiskGUID = "{33333333-3333-3333-3333-333333333333}"
					case "partition":
						row.PartitionGUID = "{44444444-4444-4444-4444-444444444444}"
					case "protection":
						row.ProtectionStatus = "On"
					case "query":
						return nil, fmt.Errorf("unavailable")
					}
				}
				return []nativeStorageRow{row}, nil
			}
			serial := func(string) (string, error) {
				serialCalls++
				if mutated && change == "serial" {
					return "fedcba9876543210", nil
				}
				return "0123456789abcdef", nil
			}
			result, err := observeNativeStorageWith(context.Background(), func() error {
				mutated = true
				if change == "metadata" {
					return fmt.Errorf("metadata refused")
				}
				return nil
			}, query, serial, func(string) (uint64, uint64, error) { return 80 << 30, 100 << 30, nil })
			if !mutated {
				t.Fatal("metadata callback never executed")
			}
			if change == "none" {
				if err != nil || len(result) != 1 || result[0].DriveLetter != "F" || queryCalls != 2 || serialCalls != 2 {
					t.Fatalf("actual coordinator did not observe both sides: %v", err)
				}
			} else if err == nil || result != nil {
				t.Fatal("same-letter physical/protection swap or failed observation became usable")
			}
		})
	}
}

func TestNativeConfigurationStorageProtectedVolumeCannotBecomeChoice(t *testing.T) {
	reads := 0
	result, err := observeNativeStorageWith(context.Background(), func() error { return nil }, func(context.Context) ([]nativeStorageRow, error) {
		return []nativeStorageRow{{DriveLetter: "C", VolumeStatus: "FullyEncrypted", ProtectionStatus: "On", EncryptionPercentage: 100}}, nil
	}, func(string) (string, error) { reads++; return "", nil }, func(string) (uint64, uint64, error) { reads++; return 0, 0, nil })
	if err != nil || len(result) != 0 || reads != 0 {
		t.Fatal("protected volume reached eligibility/identity work")
	}
}

func TestNativeConfigurationActualSystemStorageQueryAndSerialReadOnly(t *testing.T) {
	rows, err := queryNativeStorage(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		serial, err := observeNativeNtfsSerial(row.DriveLetter)
		if err != nil {
			t.Fatal(err)
		}
		if len(serial) != 16 || strings.Trim(serial, "0123456789abcdef") != "" {
			t.Fatal("full NTFS serial not observed")
		}
	}
	if len(rows) == 0 {
		t.Fatal("actual Windows query observed no fixed NTFS GPT volume; runtime control inconclusive")
	}
}

func TestNativeConfigurationStorageIgnoresInheritedModuleShadow(t *testing.T) {
	root := t.TempDir()
	module := filepath.Join(root, "Storage")
	if err := os.MkdirAll(module, 0700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(root, "shadow-loaded")
	script := "[IO.File]::WriteAllText('" + strings.ReplaceAll(marker, "'", "''") + "','untrusted module loaded'); throw 'shadow module'"
	if err := os.WriteFile(filepath.Join(module, "Storage.psm1"), []byte(script), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PSModulePath", root)
	rows, err := queryNativeStorage(context.Background())
	if err != nil || len(rows) == 0 {
		t.Fatalf("trusted system query did not execute: %v", err)
	}
	if _, err := os.Lstat(marker); !os.IsNotExist(err) {
		t.Fatal("inherited module shadow executed")
	}
}
