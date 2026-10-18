//go:build !windows

package main

import "fmt"

// The volume holding root.disk is an NTFS volume Windows mounts; other
// platforms have no record of it.
func platformVolumeSerial(root string) (volumeSerial, error) {
	return volumeSerial{}, fmt.Errorf("volume identity requires Windows")
}
