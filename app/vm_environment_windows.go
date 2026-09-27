//go:build windows

package main

import (
	"golang.org/x/sys/windows"
	"path/filepath"
)

// An elevated QEMU must not inherit user DLL/plugin/config search overrides.
// Start with a whitelist; the system directory comes from the Windows API,
// never from a caller-controlled SystemRoot or PATH environment variable.
func vmProcessEnvironment(runtimeDir, tempDir string) []string {
	system, err := windows.GetSystemDirectory()
	if err != nil {
		return []string{"PATH=" + runtimeDir, "TEMP=" + tempDir, "TMP=" + tempDir}
	}
	root := filepath.Dir(system)
	return []string{"SystemRoot=" + root, "WINDIR=" + root, "PATH=" + runtimeDir + ";" + system, "TEMP=" + tempDir, "TMP=" + tempDir, "HOME=" + tempDir, "USERPROFILE=" + tempDir, "APPDATA=" + tempDir, "LOCALAPPDATA=" + tempDir}
}
