// Package runtimebundle installs a complete authenticated Windows VM runtime.
package runtimebundle

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"wootc/internal/artifactauth"
)

const (
	MaxArchiveBytes  = 256 << 20
	MaxExpandedBytes = 512 << 20
	MaxFileBytes     = 128 << 20
	MaxFiles         = 8192
)

// Install verifies the archive against a hash from an authenticated outer
// release manifest, then verifies the inner manifest and every file. The caller
// must hold the VM lease and supply an already protected, audited parent.
// Publication is one rename; an existing parent/qemu is never updated in place.
// A crash can leave a private .qemu-stage-* directory, never a partial qemu tree.
func Install(ctx context.Context, archivePath, parent, expectedHash, publicKey string) error {
	want, err := hex.DecodeString(expectedHash)
	if err != nil || len(want) != sha256.Size {
		return fmt.Errorf("invalid runtime archive hash")
	}
	f, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	if !st.Mode().IsRegular() || st.Size() <= 0 || st.Size() > MaxArchiveBytes {
		return fmt.Errorf("runtime archive exceeds bounds or is not a regular file")
	}
	hash := sha256.New()
	n, err := io.Copy(hash, io.LimitReader(&contextReader{ctx, f}, MaxArchiveBytes+1))
	if err != nil {
		return err
	}
	if n != st.Size() {
		return fmt.Errorf("runtime archive size changed")
	}
	if !strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), expectedHash) {
		return fmt.Errorf("runtime archive checksum mismatch")
	}
	z, err := zip.NewReader(f, st.Size())
	if err != nil {
		return err
	}
	files, err := inspect(z)
	if err != nil {
		return err
	}
	manifest, err := readFile(files["SHA256SUMS"], artifactauth.MaxManifestSize)
	if err != nil {
		return err
	}
	signature, err := readFile(files["SHA256SUMS.sig"], 64)
	if err != nil {
		return err
	}
	sums, err := artifactauth.Verify(publicKey, manifest, signature)
	if err != nil {
		return err
	}
	if len(sums)+2 != len(files) {
		return fmt.Errorf("runtime manifest and archive differ")
	}
	for name := range sums {
		if name == "SHA256SUMS" || name == "SHA256SUMS.sig" || files[name] == nil {
			return fmt.Errorf("runtime manifest file missing or reserved: %s", name)
		}
	}
	for _, name := range []string{"qemu-system-x86_64.exe", "share/edk2-x86_64-code.fd", "share/edk2-i386-vars.fd", "builder-vmlinuz", "builder-initramfs.img", "builder-protocol.json"} {
		if files[name] == nil {
			return fmt.Errorf("required runtime file missing: %s", name)
		}
	}
	// Metadata was authenticated above. Re-reading it during extraction must
	// produce those exact bytes too, even if the source archive changes.
	for name, data := range map[string][]byte{"SHA256SUMS": manifest, "SHA256SUMS.sig": signature} {
		sum := sha256.Sum256(data)
		sums[name] = hex.EncodeToString(sum[:])
	}
	if err = absent(filepath.Join(parent, "qemu")); err != nil {
		return err
	}
	stage, err := os.MkdirTemp(parent, ".qemu-stage-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	for name, file := range files {
		if err = ctx.Err(); err != nil {
			return err
		}
		target := filepath.Join(stage, filepath.FromSlash(name))
		if err = os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			return err
		}
		if err = extract(ctx, file, target, sums[name]); err != nil {
			return err
		}
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	if err = absent(filepath.Join(parent, "qemu")); err != nil {
		return err
	}
	return os.Rename(stage, filepath.Join(parent, "qemu"))
}

func absent(path string) error {
	_, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	return fmt.Errorf("runtime already exists; preserve it until a stopped-VM update: %s", path)
}

func inspect(z *zip.Reader) (map[string]*zip.File, error) {
	if len(z.File) < 3 || len(z.File) > MaxFiles {
		return nil, fmt.Errorf("runtime archive file count exceeds bounds")
	}
	files := map[string]*zip.File{}
	spellings := map[string]string{}
	var expanded uint64
	for _, file := range z.File {
		if !strings.HasPrefix(file.Name, "qemu/") || !file.Mode().IsRegular() {
			return nil, fmt.Errorf("runtime entry must be a regular file under qemu: %s", file.Name)
		}
		name := strings.TrimPrefix(file.Name, "qemu/")
		parts := strings.Split(name, "/")
		for i, part := range parts {
			if !validComponent(part) {
				return nil, fmt.Errorf("unsafe Windows runtime path: %s", name)
			}
			prefix := strings.Join(parts[:i+1], "/")
			folded := strings.ToLower(prefix)
			if prior, ok := spellings[folded]; ok && prior != prefix {
				return nil, fmt.Errorf("runtime path has conflicting case: %s", name)
			}
			spellings[folded] = prefix
		}
		if files[name] != nil {
			return nil, fmt.Errorf("duplicate runtime entry: %s", name)
		}
		if file.UncompressedSize64 > MaxFileBytes {
			return nil, fmt.Errorf("runtime file exceeds bounds: %s", name)
		}
		expanded += file.UncompressedSize64
		if expanded > MaxExpandedBytes {
			return nil, fmt.Errorf("expanded runtime exceeds bounds")
		}
		files[name] = file
	}
	for name := range files {
		parts := strings.Split(name, "/")
		for i := 1; i < len(parts); i++ {
			if files[strings.Join(parts[:i], "/")] != nil {
				return nil, fmt.Errorf("runtime file is also a directory: %s", name)
			}
		}
	}
	return files, nil
}

func validComponent(part string) bool {
	if part == "" || part == "." || part == ".." || strings.TrimRight(part, ". ") != part {
		return false
	}
	for _, char := range part {
		if char <= 32 || char > 126 || strings.ContainsRune(`\:<>"|?*`, char) {
			return false
		}
	}
	stem := strings.ToUpper(strings.SplitN(part, ".", 2)[0])
	switch stem {
	case "CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$":
		return false
	}
	return !(len(stem) == 4 && (strings.HasPrefix(stem, "COM") || strings.HasPrefix(stem, "LPT")) && stem[3] >= '1' && stem[3] <= '9')
}

func readFile(file *zip.File, limit int64) ([]byte, error) {
	if file == nil || file.UncompressedSize64 > uint64(limit) {
		return nil, fmt.Errorf("runtime metadata missing or exceeds bounds")
	}
	r, err := file.Open()
	if err != nil {
		return nil, err
	}
	defer r.Close()
	data, err := io.ReadAll(io.LimitReader(r, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("runtime metadata exceeds bounds")
	}
	return data, nil
}

func extract(ctx context.Context, file *zip.File, target, checksum string) error {
	r, err := file.Open()
	if err != nil {
		return err
	}
	defer r.Close()
	w, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer w.Close()
	hash := sha256.New()
	n, err := io.Copy(io.MultiWriter(w, hash), io.LimitReader(&contextReader{ctx, r}, MaxFileBytes+1))
	if err != nil {
		return err
	}
	if n > MaxFileBytes || uint64(n) != file.UncompressedSize64 {
		return fmt.Errorf("runtime file size mismatch: %s", file.Name)
	}
	if checksum != "" && hex.EncodeToString(hash.Sum(nil)) != checksum {
		return fmt.Errorf("runtime file checksum mismatch: %s", file.Name)
	}
	if err = w.Sync(); err != nil {
		return err
	}
	return w.Close()
}

type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r *contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(p)
}
