//go:build windows

package main

import (
	"golang.org/x/sys/windows"
	"os"
	"path/filepath"
)

func currentVMStoragePlan() (vmStoragePlan, vmStorageMinimums, error) {
	plan := defaultVMStoragePlan()
	metadata, err := readLocalMetadata(filepath.Join(qemuDir(), "builder-protocol.json"), 64<<10)
	if err != nil {
		return plan, vmStorageMinimums{}, err
	}
	minimums, err := parseVMStorageMinimums(metadata)
	if err != nil {
		return plan, minimums, err
	}
	_, err = plan.requiredFree(minimums)
	return plan, minimums, err
}

func createVMImageFiles() error {
	// The caller verified the complete signed runtime before it acquired the
	// image lease. Metadata cannot lower the image profile by itself.
	plan, minimums, err := currentVMStoragePlan()
	if err != nil {
		return err
	}
	available, err := vmFreeBytes(wootcDir())
	if err != nil {
		return err
	}
	if err := plan.admit(minimums, available); err != nil {
		return err
	}
	for _, disk := range []struct {
		path     string
		capacity uint64
	}{
		{managedVMRootDisk(), plan.Target},
		{filepath.Join(previewDir(), "scratch.disk"), plan.Scratch},
	} {
		path, capacity := disk.path, disk.capacity
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
