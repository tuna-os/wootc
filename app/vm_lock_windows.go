//go:build windows

package main

import (
	"crypto/sha256"
	"fmt"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Mutex ownership is thread-bound on Windows. A dedicated pinned goroutine
// retains it until release, including across a QEMU process lifetime. The
// kernel abandons the mutex after an engine crash; durable VM state still
// blocks an automatic restart of an image that may have been interrupted.
func acquireVMLock(disk string) (func(), error) {
	path, err := filepath.Abs(disk)
	if err != nil {
		return nil, err
	}
	hash := sha256.Sum256([]byte(strings.ToUpper(filepath.Clean(path))))
	name, _ := windows.UTF16PtrFromString(fmt.Sprintf(`Global\wootc-image-%x`, hash))
	ready := make(chan error, 1)
	release := make(chan struct{})
	done := make(chan struct{})
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		defer close(done)
		sd, err := windows.SecurityDescriptorFromString("D:P(A;;GA;;;SY)(A;;GA;;;BA)")
		if err != nil {
			ready <- err
			return
		}
		attr := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: sd}
		handle, err := windows.CreateMutex(&attr, false, name)
		if err != nil && err != windows.ERROR_ALREADY_EXISTS {
			ready <- err
			return
		}
		defer windows.CloseHandle(handle)
		result, err := windows.WaitForSingleObject(handle, 0)
		if err != nil {
			ready <- err
			return
		}
		if result != windows.WAIT_OBJECT_0 && result != windows.WAIT_ABANDONED {
			ready <- fmt.Errorf("this Linux disk is in use by another operation or VM")
			return
		}
		ready <- nil
		<-release
		_ = windows.ReleaseMutex(handle)
	}()
	if err := <-ready; err != nil {
		<-done
		return nil, err
	}
	var once sync.Once
	return func() { once.Do(func() { close(release); <-done }) }, nil
}

// Called while holding the image lease. It also catches a QEMU process left
// alive outside our manager: Windows must permit an exclusive image handle.
func verifyVMDiskReleased(path string) error {
	ptr, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	h, err := windows.CreateFile(ptr, windows.GENERIC_READ, 0, nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err == windows.ERROR_FILE_NOT_FOUND || err == windows.ERROR_PATH_NOT_FOUND {
		return nil
	}
	if err != nil {
		return fmt.Errorf("Linux disk still has open handles; stop its VM first: %w", err)
	}
	return windows.CloseHandle(h)
}
