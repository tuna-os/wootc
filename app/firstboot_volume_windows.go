//go:build windows

package main

import (
	"encoding/binary"
	"fmt"
	"path/filepath"

	"golang.org/x/sys/windows"
)

// FSCTL_GET_NTFS_VOLUME_DATA: CTL_CODE(FILE_DEVICE_FILE_SYSTEM, 25,
// METHOD_BUFFERED, FILE_ANY_ACCESS). The reply starts with the 64-bit NTFS
// volume serial number, the value Linux reports as the volume UUID.
const fsctlGetNTFSVolumeData = 0x00090064

// platformVolumeSerial identifies the volume under root. The full 64-bit
// serial needs a volume handle (administrators; the installer and the E2E
// agent both run elevated). The low 32 bits are what GetVolumeInformation
// returns to anyone, and are the fallback.
func platformVolumeSerial(root string) (volumeSerial, error) {
	var serial volumeSerial
	volume := filepath.VolumeName(root)
	if len(volume) != 2 || volume[1] != ':' {
		return serial, fmt.Errorf("invalid installer state location %q", root)
	}
	if h, err := openVolumeForQuery(`\\.\` + volume); err == nil {
		var reply [256]byte
		var returned uint32
		if err := windows.DeviceIoControl(h, fsctlGetNTFSVolumeData, nil, 0, &reply[0], uint32(len(reply)), &returned, nil); err == nil && returned >= 8 {
			serial.serial64, serial.have64 = binary.LittleEndian.Uint64(reply[:8]), true
		}
		windows.CloseHandle(h)
	}
	p, err := windows.UTF16PtrFromString(volume + `\`)
	if err != nil {
		return serial, err
	}
	if err := windows.GetVolumeInformation(p, nil, 0, &serial.serial32, nil, nil, nil, 0); err == nil {
		serial.have32 = true
	} else if !serial.have64 {
		return serial, err
	}
	return serial, nil
}

func openVolumeForQuery(path string) (windows.Handle, error) {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return windows.InvalidHandle, err
	}
	return windows.CreateFile(p, 0, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
}
