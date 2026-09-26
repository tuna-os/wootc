package runtimebundle

import (
	"archive/zip"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"wootc/internal/artifactauth"
)

type entry struct {
	name string
	data []byte
	mode os.FileMode
}

func fixture(t *testing.T, mutate func(*[]entry, *string)) (string, string, string) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	var entries []entry
	var manifest strings.Builder
	for _, name := range []string{"qemu-system-x86_64.exe", "share/edk2-x86_64-code.fd", "share/edk2-i386-vars.fd", "builder-vmlinuz", "builder-initramfs.img", "builder-protocol.json", "dependency.dll"} {
		data := []byte("test runtime " + name)
		fmt.Fprintf(&manifest, "%x  %s\n", sha256.Sum256(data), name)
		entries = append(entries, entry{"qemu/" + name, data, 0600})
	}
	text := manifest.String()
	if mutate != nil {
		mutate(&entries, &text)
	}
	entries = append(entries, entry{"qemu/SHA256SUMS", []byte(text), 0600}, entry{"qemu/SHA256SUMS.sig", artifactauth.Sign(private, []byte(text)), 0600})
	return makeZip(t, entries), hex.EncodeToString(public), text
}

func makeZip(t *testing.T, entries []entry) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "runtime.zip")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	z := zip.NewWriter(f)
	for _, e := range entries {
		h := &zip.FileHeader{Name: e.name, Method: zip.Deflate}
		h.SetMode(e.mode)
		w, err := z.CreateHeader(h)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = w.Write(e.data); err != nil {
			t.Fatal(err)
		}
	}
	if err = z.Close(); err != nil {
		t.Fatal(err)
	}
	if err = f.Close(); err != nil {
		t.Fatal(err)
	}
	return path
}

func archiveHash(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf("%x", sha256.Sum256(data))
}

func TestInstallAndPreserveExisting(t *testing.T) {
	archive, key, _ := fixture(t, nil)
	parent := t.TempDir()
	if err := Install(context.Background(), archive, parent, archiveHash(t, archive), key); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(parent, "qemu", "dependency.dll"))
	if err != nil || string(got) != "test runtime dependency.dll" {
		t.Fatalf("wrong installed file: %q %v", got, err)
	}
	if err = Install(context.Background(), archive, parent, archiveHash(t, archive), key); err == nil {
		t.Fatal("overwrote existing runtime")
	}
	entries, err := os.ReadDir(parent)
	if err != nil || len(entries) != 1 || entries[0].Name() != "qemu" {
		t.Fatalf("left staging files: %v %v", entries, err)
	}
}

func TestRejectArchiveAndPreserveParent(t *testing.T) {
	cases := map[string]func(*[]entry, *string){
		"extra DLL":             func(e *[]entry, _ *string) { *e = append(*e, entry{"qemu/unsigned.dll", []byte("extra"), 0600}) },
		"missing DLL":           func(e *[]entry, _ *string) { *e = (*e)[:len(*e)-1] },
		"edited payload":        func(e *[]entry, _ *string) { (*e)[0].data = []byte("changed") },
		"duplicate":             func(e *[]entry, _ *string) { *e = append(*e, (*e)[0]) },
		"directory case":        func(e *[]entry, _ *string) { (*e)[2].name = "qemu/Share/edk2-i386-vars.fd" },
		"file case":             func(e *[]entry, _ *string) { *e = append(*e, entry{"qemu/DEPENDENCY.dll", []byte("extra"), 0600}) },
		"traversal":             func(e *[]entry, _ *string) { (*e)[0].name = "qemu/../escape" },
		"drive":                 func(e *[]entry, _ *string) { (*e)[0].name = "qemu/C:/escape" },
		"backslash":             func(e *[]entry, _ *string) { (*e)[0].name = `qemu/share\escape` },
		"alternate stream":      func(e *[]entry, _ *string) { (*e)[0].name = "qemu/file:stream" },
		"device":                func(e *[]entry, _ *string) { (*e)[0].name = "qemu/NUL.dll" },
		"trailing dot":          func(e *[]entry, _ *string) { (*e)[0].name = "qemu/dependency.dll." },
		"absolute":              func(e *[]entry, _ *string) { (*e)[0].name = "/qemu/escape" },
		"symlink":               func(e *[]entry, _ *string) { (*e)[0].mode = os.ModeSymlink | 0777 },
		"unmanifested required": func(e *[]entry, s *string) { *e = (*e)[1:]; *s = strings.Join(strings.Split(*s, "\n")[1:], "\n") },
	}
	names := make([]string, 0, len(cases))
	for name := range cases {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		t.Run(name, func(t *testing.T) {
			archive, key, _ := fixture(t, cases[name])
			parent := t.TempDir()
			if err := Install(context.Background(), archive, parent, archiveHash(t, archive), key); err == nil {
				t.Fatal("accepted invalid bundle")
			}
			entries, err := os.ReadDir(parent)
			if err != nil || len(entries) != 0 {
				t.Fatalf("published invalid or partial runtime: %v %v", entries, err)
			}
		})
	}
}

func TestOuterHashSignatureAndCancellation(t *testing.T) {
	archive, key, _ := fixture(t, nil)
	for _, kind := range []string{"outer hash", "signature", "cancel"} {
		t.Run(kind, func(t *testing.T) {
			parent := t.TempDir()
			hash := archiveHash(t, archive)
			useKey := key
			ctx := context.Background()
			switch kind {
			case "outer hash":
				hash = strings.Repeat("0", 64)
			case "signature":
				useKey = strings.Repeat("0", 64)
			case "cancel":
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}
			if err := Install(ctx, archive, parent, hash, useKey); err == nil {
				t.Fatal("accepted untrusted or canceled installation")
			}
			entries, _ := os.ReadDir(parent)
			if len(entries) != 0 {
				t.Fatal("left partial runtime")
			}
		})
	}
}

func TestRejectExpansionBounds(t *testing.T) {
	for _, files := range [][]*zip.File{
		make([]*zip.File, MaxFiles+1),
		{{FileHeader: zip.FileHeader{Name: "qemu/large", UncompressedSize64: MaxFileBytes + 1}}, {FileHeader: zip.FileHeader{Name: "qemu/a"}}, {FileHeader: zip.FileHeader{Name: "qemu/b"}}},
		{{FileHeader: zip.FileHeader{Name: "qemu/a", UncompressedSize64: MaxFileBytes}}, {FileHeader: zip.FileHeader{Name: "qemu/b", UncompressedSize64: MaxFileBytes}}, {FileHeader: zip.FileHeader{Name: "qemu/c", UncompressedSize64: MaxFileBytes}}, {FileHeader: zip.FileHeader{Name: "qemu/d", UncompressedSize64: MaxFileBytes}}, {FileHeader: zip.FileHeader{Name: "qemu/e", UncompressedSize64: 1}}},
	} {
		if _, err := inspect(&zip.Reader{File: files}); err == nil {
			t.Fatal("accepted oversized ZIP metadata")
		}
	}
}

// An opt-in fixture test exercises the same installer on the actual signed
// runtime archive, on Linux or native Windows. No production path reads these.
func TestRealArchive(t *testing.T) {
	archive := os.Getenv("WOOTC_TEST_RUNTIME_ARCHIVE")
	if archive == "" {
		t.Skip("no real runtime fixture supplied")
	}
	key := os.Getenv("WOOTC_TEST_RUNTIME_PUBLIC_KEY")
	parent := t.TempDir()
	if err := Install(context.Background(), archive, parent, archiveHash(t, archive), key); err != nil {
		t.Fatal(err)
	}
	count := 0
	if err := filepath.WalkDir(filepath.Join(parent, "qemu"), func(_ string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.IsDir() {
			count++
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	t.Logf("authenticated and installed %d runtime files", count)
}
