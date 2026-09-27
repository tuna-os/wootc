//go:build windows

package main

import (
	"fmt"
	"golang.org/x/sys/windows"
	"path/filepath"
)

func readStatusState() (LifecycleState, bool, error) {
	drives, err := windows.GetLogicalDrives()
	if err != nil {
		return LifecycleState{}, false, err
	}
	var roots []string
	for i := uint32(0); i < 26; i++ {
		if drives&(1<<i) == 0 {
			continue
		}
		volume := string(rune('A'+i)) + `:\`
		p, err := windows.UTF16PtrFromString(volume)
		if err != nil {
			return LifecycleState{}, false, err
		}
		if windows.GetDriveType(p) == windows.DRIVE_FIXED {
			roots = append(roots, volume+"wootc")
		}
	}
	state, root, found, err := discoverStatusState(roots, auditTrustedStateDirectory)
	if err == nil && found {
		setStorageDrive(filepath.VolumeName(root)[:1])
	}
	return state, found, err
}

// This audit cannot create a directory or repair an unsafe ACL.
func auditTrustedStateDirectory(root string) error {
	volume := filepath.VolumeName(root)
	if len(volume) != 2 || volume[1] != ':' || filepath.Clean(root) != volume+`\wootc` {
		return fmt.Errorf("invalid installer state location %q", root)
	}
	if err := inspectStateObject(volume+`\`, true); err != nil {
		return fmt.Errorf("unsafe status volume %s: %w", volume, err)
	}
	return auditStatusTree(root, func(path string) error {
		if err := inspectStateObject(path, false); err != nil {
			return fmt.Errorf("unsafe status location %s: %w", path, err)
		}
		return nil
	})
}
