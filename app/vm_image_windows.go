//go:build windows

package main

import (
	"fmt"
	"golang.org/x/sys/windows"
	"os"
	"path/filepath"
)

func createVMImageFiles() error {
	available, err := vmFreeBytes(wootcDir())
	if err != nil {
		return err
	}
	const capacity = uint64(40) << 30
	if available < 2*capacity+vmWindowsReserveBytes {
		return fmt.Errorf("VM preparation needs at least 88 GB free for the Linux disk, scratch space and an 8 GB Windows reserve")
	}
	for _, path := range []string{managedVMRootDisk(), filepath.Join(previewDir(), "scratch.disk")} {
		file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
		if err != nil {
			return err
		}
		var returned uint32
		// Sparse files are safe here: QEMU uses Windows file APIs. Native promotion
		// must separately prove allocation/NTFS compatibility before mounting offline.
		err = windows.DeviceIoControl(windows.Handle(file.Fd()), windows.FSCTL_SET_SPARSE, nil, 0, nil, 0, &returned, nil)
		if err == nil {
			err = file.Truncate(int64(capacity))
		}
		if err == nil {
			err = file.Sync()
		}
		closeErr := file.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}

func vmFreeBytes(root string) (uint64, error) {
	pointer, err := windows.UTF16PtrFromString(root)
	if err != nil {
		return 0, err
	}
	var available, total, free uint64
	err = windows.GetDiskFreeSpaceEx(pointer, &available, &total, &free)
	return available, err
}
