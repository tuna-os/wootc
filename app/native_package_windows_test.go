//go:build windows

package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func TestNativePackageProtectedFilesAndManifest(t *testing.T) {
	// Fresh hosted-test folder only, never installation state or actual packages.
	parent, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, 0)
	if err != nil {
		t.Fatal(err)
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(parent, "wootc-native-package-test-"+hex.EncodeToString(nonce[:]))
	if err := prepareTrustedStateTree(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(root); err != nil {
			t.Error(err)
		}
	})
	oldBuild := nativeBuildID
	nativeBuildID = strings.Repeat("a", 40)
	t.Cleanup(func() { nativeBuildID = oldBuild })
	manifest := nativePackageManifest{SchemaVersion: 1, ProtocolVersion: 1, BuildID: nativeBuildID, BrandID: brandID, Files: map[string]string{}}
	for _, relative := range []string{"wootc-engine.exe", "Wootc.Shell.exe", "Wootc.Shell.dll", "Wootc.Shell.pri", "Branding/brand.json"} {
		path := filepath.Join(root, filepath.FromSlash(relative))
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		data := []byte("public package fixture " + relative)
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(data)
		manifest.Files[relative] = hex.EncodeToString(digest[:])
	}
	writeManifest := func() {
		t.Helper()
		data, err := json.Marshal(manifest)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "native-package.json"), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	writeManifest()
	engine := filepath.Join(root, "wootc-engine.exe")
	if _, err := readNativePackage(engine); err != nil {
		t.Fatal(err)
	}
	t.Run("changed managed assembly", func(t *testing.T) {
		path := filepath.Join(root, "Wootc.Shell.dll")
		original, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("other build"), 0600); err != nil {
			t.Fatal(err)
		}
		defer os.WriteFile(path, original, 0600)
		if _, err := readNativePackage(engine); err == nil {
			t.Fatal("changed managed code accepted")
		}
	})
	t.Run("unrecorded dependency", func(t *testing.T) {
		path := filepath.Join(root, "foreign.dll")
		if err := os.WriteFile(path, []byte("foreign"), 0600); err != nil {
			t.Fatal(err)
		}
		defer os.Remove(path)
		if _, err := readNativePackage(engine); err == nil {
			t.Fatal("unrecorded dependency accepted")
		}
	})
	for _, entry := range []string{"../outside", "C:/outside", "Branding\\brand.json", "Branding/../outside", "/outside"} {
		t.Run("invalid manifest "+entry, func(t *testing.T) {
			manifest.Files[entry] = strings.Repeat("b", 64)
			writeManifest()
			defer func() { delete(manifest.Files, entry); writeManifest() }()
			if _, err := readNativePackage(engine); err == nil {
				t.Fatal("unsafe artifact path accepted")
			}
		})
	}
	t.Run("wrong build", func(t *testing.T) {
		manifest.BuildID = strings.Repeat("b", 40)
		writeManifest()
		defer func() { manifest.BuildID = nativeBuildID; writeManifest() }()
		if _, err := readNativePackage(engine); err == nil {
			t.Fatal("other build manifest accepted")
		}
	})
	t.Run("writable assembly", func(t *testing.T) {
		applyTestDACL(t, filepath.Join(root, "Wootc.Shell.dll"), "O:BAD:P(A;;FA;;;BA)(A;;FW;;;BU)")
		if _, err := readNativePackage(engine); err == nil {
			t.Fatal("user-writable managed assembly accepted")
		}
	})
}
