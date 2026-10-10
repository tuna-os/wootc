//go:build windows

package main

import (
	"fmt"
	"golang.org/x/sys/windows"
)

type nativeConfigurationRoot struct {
	handle   windows.Handle
	identity windows.ByHandleFileInformation
}

// Capture the identity immediately and pin the original object. SHARE_DELETE
// permits the real swap counterexample; comparing eagerly read file indexes
// still rejects the replacement instead of lazily reopening the old pathname.
func captureNativeConfigurationRoot(path string) (*nativeConfigurationRoot, error) {
	pointer, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, err
	}
	handle, err := windows.CreateFile(pointer, windows.READ_CONTROL|windows.FILE_READ_ATTRIBUTES, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, err
	}
	root := &nativeConfigurationRoot{handle: handle}
	if err := windows.GetFileInformationByHandle(handle, &root.identity); err != nil {
		root.close()
		return nil, err
	}
	if root.identity.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 || root.identity.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY == 0 {
		root.close()
		return nil, fmt.Errorf("configuration root must be a regular directory")
	}
	return root, nil
}
func (root *nativeConfigurationRoot) close() {
	if root.handle != 0 {
		windows.CloseHandle(root.handle)
		root.handle = 0
	}
}
func (root *nativeConfigurationRoot) matches(path string) (bool, error) {
	current, err := captureNativeConfigurationRoot(path)
	if err != nil {
		return false, err
	}
	defer current.close()
	var retained windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(root.handle, &retained); err != nil {
		return false, err
	}
	equal := func(a, b windows.ByHandleFileInformation) bool {
		return a.VolumeSerialNumber == b.VolumeSerialNumber && a.FileIndexHigh == b.FileIndexHigh && a.FileIndexLow == b.FileIndexLow
	}
	return equal(root.identity, retained) && equal(root.identity, current.identity), nil
}
