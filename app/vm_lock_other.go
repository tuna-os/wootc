//go:build !windows

package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
)

func acquireVMLock(disk string) (func(), error) {
	path, err := filepath.Abs(disk)
	if err != nil {
		return nil, err
	}
	hash := sha256.Sum256([]byte(path))
	f, err := os.OpenFile(filepath.Join(os.TempDir(), fmt.Sprintf("wootc-image-%x.lock", hash)), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("Linux disk is in use: %w", err)
	}
	var once sync.Once
	return func() { once.Do(func() { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN); _ = f.Close() }) }, nil
}
func verifyVMDiskReleased(string) error { return nil }
