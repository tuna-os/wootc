//go:build windows

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"golang.org/x/sys/windows"
	"io"
	"io/fs"
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
		retainNativeStorageQueryFailure(t, err)
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
		retainNativeStorageQueryFailure(t, err)
		t.Fatalf("trusted system query did not execute: %v", err)
	}
	if _, err := os.Lstat(marker); !os.IsNotExist(err) {
		t.Fatal("inherited module shadow executed")
	}
}

func TestNativeConfigurationStorageIgnoresInheritedWindowsDirectory(t *testing.T) {
	root := t.TempDir()
	// Case-insensitive replacement must remove both inherited spellings before
	// the trusted manifest resolves its required native assembly.
	t.Setenv("windir", root)
	t.Setenv("SystemRoot", root)
	rows, err := queryNativeStorage(context.Background())
	if err != nil || len(rows) == 0 {
		retainNativeStorageQueryFailure(t, err)
		t.Fatalf("kernel-bound Windows query did not execute: %v", err)
	}
}

func retainNativeStorageQueryFailure(t *testing.T, err error) {
	t.Helper()
	var failure *nativeStorageObservationFailure
	if !errors.As(err, &failure) {
		return
	}
	base := os.Getenv("WOOTC_NATIVE_QUERY_PROOF_DIR")
	if base == "" {
		return
	}
	if err := os.MkdirAll(base, 0700); err != nil {
		t.Fatal(err)
	}
	prefix := filepath.Join(base, t.Name())
	if err := os.WriteFile(prefix+".stdout.raw", failure.Stdout, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(prefix+".stderr.raw", failure.Stderr, 0600); err != nil {
		t.Fatal(err)
	}
	record, _ := json.Marshal(map[string]any{"schemaVersion": 1, "test": t.Name(), "exitCode": failure.ExitCode, "bounded": true, "scope": "fixed read-only source; diagnostic catch emits stage/type/numeric fields only"})
	if err := os.WriteFile(prefix+".json", record, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestNativeConfigurationActualTrustedModuleManifestInventory(t *testing.T) {
	system, err := windows.GetSystemDirectory()
	if err != nil {
		t.Fatal(err)
	}
	base := os.Getenv("WOOTC_NATIVE_QUERY_PROOF_DIR")
	if base == "" {
		t.Fatal("private hosted diagnostic destination required")
	}
	destination := filepath.Join(base, "trusted-system-modules")
	if err := os.Mkdir(destination, 0700); err != nil {
		t.Fatal(err)
	}
	type manifest struct {
		Path   string `json:"path"`
		Size   int64  `json:"size"`
		SHA256 string `json:"sha256"`
	}
	inventory := map[string][]manifest{}
	for _, name := range []string{"Storage", "BitLocker", "Microsoft.PowerShell.Utility"} {
		inventory[name] = []manifest{}
		module := filepath.Join(system, "WindowsPowerShell", "v1.0", "Modules", name)
		if err := auditNativePackagePath(module); err != nil {
			t.Fatal(err)
		}
		if err := auditNativeStatusTree(context.Background(), module, 512, func(path string) error { return inspectStateObject(path, false) }); err != nil {
			t.Fatal(err)
		}
		count := 0
		err := filepath.WalkDir(module, func(path string, entry fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			count++
			if count > 512 {
				return fmt.Errorf("module inventory exceeds bound")
			}
			if entry.IsDir() {
				return nil
			}
			if !strings.EqualFold(entry.Name(), name+".psd1") && !(name == "Storage" && strings.EqualFold(entry.Name(), "StorageScripts.psm1")) {
				return nil
			}
			file, err := os.Open(path)
			if err != nil {
				return err
			}
			info, err := file.Stat()
			if err != nil || !info.Mode().IsRegular() || info.Size() > 1024*1024 {
				file.Close()
				return fmt.Errorf("trusted module source exceeds diagnostic bound")
			}
			data, err := io.ReadAll(io.LimitReader(file, 1024*1024+1))
			closeErr := file.Close()
			if err != nil {
				return err
			}
			if closeErr != nil {
				return closeErr
			}
			if len(data) > 1024*1024 {
				return fmt.Errorf("trusted module source exceeds diagnostic bound")
			}
			relative, err := filepath.Rel(module, path)
			if err != nil {
				return err
			}
			hash := sha256.Sum256(data)
			inventory[name] = append(inventory[name], manifest{Path: relative, Size: int64(len(data)), SHA256: hex.EncodeToString(hash[:])})
			owned := filepath.Join(destination, name, relative)
			if err := os.MkdirAll(filepath.Dir(owned), 0700); err != nil {
				return err
			}
			return os.WriteFile(owned, data, 0600)
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	data, err := json.MarshalIndent(map[string]any{"schemaVersion": 1, "scope": "actual protected system module manifests only; no module execution or state mutation", "modules": inventory}, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(destination, "inventory.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestNativeConfigurationActualUtilityDependencyOrderCounter(t *testing.T) {
	original := nativeStorageQuery
	defer func() { nativeStorageQuery = original }()
	rows, err := queryNativeStorage(context.Background())
	if err != nil || len(rows) == 0 {
		retainNativeStorageQueryFailure(t, err)
		t.Fatalf("correct dependency order did not observe system storage: %v", err)
	}
	utility := `Import-Module -Name "$PSHOME\Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1" -ErrorAction Stop` + "\n"
	if strings.Count(original, utility) != 1 {
		t.Fatal("actual protected Utility import not found")
	}
	// Recreate the measured old ordering without changing module discovery,
	// interpreter, ACL gates, environment or any storage/protection state.
	broken := strings.Replace(original, utility, "", 1)
	bitlocker := `Import-Module -Name "$PSHOME\Modules\BitLocker\BitLocker.psd1" -ErrorAction Stop` + "\n"
	if !strings.Contains(broken, bitlocker) {
		t.Fatal("actual protected BitLocker import not found")
	}
	nativeStorageQuery = strings.Replace(broken, bitlocker, bitlocker+utility, 1)
	_, err = queryNativeStorage(context.Background())
	var failure *nativeStorageObservationFailure
	if !errors.As(err, &failure) || !strings.Contains(string(failure.Stderr), "loader=command-not-found") {
		t.Fatal("old dependency-order counterexample did not refuse with observed loader class")
	}
	nativeStorageQuery = original
	rows, err = queryNativeStorage(context.Background())
	if err != nil || len(rows) == 0 {
		retainNativeStorageQueryFailure(t, err)
		t.Fatalf("restored dependency order did not observe system storage: %v", err)
	}
}
