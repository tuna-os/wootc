package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// New installation is not consent to replace or reinstall an existing image.
// Recovery re-arms the existing boot entry through its own explicit operation.
func requireNewRootDiskPath(path string) error {
	_, err := os.Lstat(path)
	if err == nil {
		return fmt.Errorf("root.disk already exists; preserving your Linux data. Use recovery for retry, or explicitly remove the existing Linux disk before a new installation")
	}
	if !os.IsNotExist(err) {
		return fmt.Errorf("inspect root.disk without changing it: %w", err)
	}
	return nil
}

func allocateNewRootDiskFile(path string, sizeBytes int64, initialize func(string) error) error {
	return allocateNewRootDiskFileWithOpen(path, sizeBytes, initialize, os.OpenFile)
}

func allocateNewRootDiskFileWithOpen(path string, sizeBytes int64, initialize func(string) error, open func(string, int, os.FileMode) (*os.File, error)) error {
	if sizeBytes <= 0 {
		return fmt.Errorf("root.disk size must be positive")
	}
	if err := requireNewRootDiskPath(path); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return fmt.Errorf("create disks directory: %w", err)
	}
	// O_EXCL protects the actual mutation if another image appears after the
	// preflight. Neither an existing regular file nor a symlink is truncated.
	f, err := open(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return fmt.Errorf("create new root.disk without replacing existing data: %w", err)
	}
	if err := f.Truncate(sizeBytes); err != nil {
		_ = f.Close()
		return fmt.Errorf("allocate new root.disk: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("close new root.disk: %w", err)
	}
	if err := initialize(path); err != nil {
		return err
	}
	st, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("verify new root.disk: %w", err)
	}
	if !st.Mode().IsRegular() || st.Size() != sizeBytes {
		return fmt.Errorf("new root.disk is not a regular file of the requested size")
	}
	return nil
}
