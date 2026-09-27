// wootc-ntfs-state-write atomically replaces lifecycle metadata while retaining
// its Windows security descriptor. The template must be a Windows-staged file.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

const maxMetadata = 65536

func descriptor(path, attribute string) ([]byte, error) {
	n, err := syscall.Getxattr(path, attribute, nil)
	if err != nil {
		return nil, err
	}
	if n < 20 || n > 65536 {
		return nil, fmt.Errorf("invalid NTFS descriptor length %d", n)
	}
	data := make([]byte, n)
	n, err = syscall.Getxattr(path, attribute, data)
	if err != nil {
		return nil, err
	}
	if n > len(data) || n < 20 {
		return nil, errors.New("descriptor changed while reading")
	}
	return data[:n], nil
}

func writeMetadata(template, target string, input io.Reader) error {
	for _, path := range []string{template, filepath.Dir(target)} {
		st, err := os.Lstat(path)
		if err != nil {
			return err
		}
		if st.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("refusing symlink %s", path)
		}
	}
	st, err := os.Stat(template)
	if err != nil {
		return err
	}
	if !st.Mode().IsRegular() {
		return errors.New("template is not a regular file")
	}
	// Read and bound the entire record before touching the destination.
	data, err := io.ReadAll(io.LimitReader(input, maxMetadata+1))
	if err != nil {
		return err
	}
	if len(data) == 0 || len(data) > maxMetadata {
		return errors.New("metadata is empty or exceeds 64 KiB")
	}
	attribute := "system.ntfs_acl"
	sd, err := descriptor(template, attribute)
	if errors.Is(err, syscall.ENODATA) || errors.Is(err, syscall.ENOTSUP) {
		attribute = "system.ntfs_security"
		sd, err = descriptor(template, attribute)
	}
	if err != nil {
		return fmt.Errorf("read Windows descriptor: %w", err)
	}
	if err = validateDescriptor(sd); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(target), ".wootc-state-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	defer f.Close()
	// Never populate a temporary record until its descriptor is protected.
	if err = syscall.Setxattr(tmp, attribute, sd, 0); err != nil {
		return fmt.Errorf("preserve Windows descriptor: %w", err)
	}
	actual, err := descriptor(tmp, attribute)
	if err != nil {
		return err
	}
	if !bytes.Equal(actual, sd) {
		return errors.New("Windows descriptor did not round-trip")
	}
	if _, err = f.Write(data); err != nil {
		return err
	}
	if err = f.Sync(); err != nil {
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if err = os.Rename(tmp, target); err != nil {
		return err
	}
	d, err := os.Open(filepath.Dir(target))
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: wootc-ntfs-state-write TEMPLATE TARGET < metadata")
		os.Exit(2)
	}
	if err := writeMetadata(os.Args[1], os.Args[2], os.Stdin); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
