//go:build windows

package main

import (
	"os"

	"golang.org/x/sys/windows"
)

// Manifest readers retain a complete old snapshot while atomic publication
// replaces its pathname. Ordinary Go opens do not share deletion on Windows,
// so they can block that replacement or fail to open during it.
func openESPManifest(path string) (*os.File, error) {
	pointer, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	handle, err := windows.CreateFile(pointer, windows.GENERIC_READ,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	return os.NewFile(uintptr(handle), path), nil
}
