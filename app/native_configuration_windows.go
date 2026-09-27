//go:build windows

package main

import (
	"context"
	"fmt"
	"path/filepath"
	"slices"
	"time"
)

func observeWindowsNativeConfiguration(ctx context.Context, selectedRoot string, selectedFound bool) (NativeConfigurationSnapshot, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	var empty NativeConfigurationSnapshot
	roots, err := windowsFixedStateRoots()
	if err != nil {
		return empty, err
	}
	validateSelection := func() error {
		_, root, found, err := selectWindowsStatusState(ctx, true)
		if err != nil {
			return err
		}
		if found != selectedFound || root != selectedRoot {
			return fmt.Errorf("configuration installation observation changed")
		}
		current, err := windowsFixedStateRoots()
		if err != nil {
			return err
		}
		if !slices.Equal(roots, current) {
			return fmt.Errorf("configuration volume set changed")
		}
		return nil
	}
	if err := validateSelection(); err != nil {
		return empty, err
	}
	var snapshot NativeConfigurationSnapshot
	storage, err := observeNativeStorage(ctx, func() error {
		var readErr error
		snapshot, readErr = readNativeConfiguration(ctx, roots, selectedRoot, selectedFound, func(root string) error {
			volume := filepath.VolumeName(root)
			if len(volume) != 2 || volume[1] != ':' || filepath.Clean(root) != volume+`\wootc` {
				return fmt.Errorf("invalid configuration location")
			}
			if err := inspectStateObject(volume+`\`, true); err != nil {
				return err
			}
			return auditNativeStatusTree(ctx, root, 4096, func(path string) error { return inspectStateObject(path, false) })
		})
		return readErr
	})
	if err != nil {
		return empty, err
	}
	if err := validateSelection(); err != nil {
		return empty, err
	}
	snapshot.StorageStatus, snapshot.Storage = "observed", storage
	return snapshot, nil
}
