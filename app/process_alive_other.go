//go:build !windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
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

// processCreationTime approximates when a running pid started from its /proc
// entry. Linux builds are development stubs; Windows uses GetProcessTimes.
func processCreationTime(pid int) (time.Time, bool) {
	if pid <= 0 {
		return time.Time{}, false
	}
	info, err := os.Stat(fmt.Sprintf("/proc/%d", pid))
	if err != nil {
		return time.Time{}, false
	}
	return info.ModTime(), true
}
