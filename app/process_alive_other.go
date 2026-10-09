//go:build !windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// processAlive reports whether pid is a running process with the same
// executable name as this one, so a reused PID never passes as a live install.
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	exe, err := os.Readlink(fmt.Sprintf("/proc/%d/exe", pid))
	if err != nil {
		return false
	}
	self, err := os.Executable()
	if err != nil {
		return false
	}
	return filepath.Base(exe) == filepath.Base(self)
}
