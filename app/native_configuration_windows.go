//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"slices"
	"time"
)

func observeWindowsNativeConfiguration(ctx context.Context, selectedRoot string, selectedFound bool) (result NativeConfigurationSnapshot, resultErr error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	timing := newNativeConfigurationTiming()
	defer func() {
		if resultErr != nil {
			var failure *nativeStorageObservationFailure
			if !errors.As(resultErr, &failure) {
				state := nativeStorageContextState(ctx)
				failure = &nativeStorageObservationFailure{ExitCode: -1, Phase: "no-child-phase-observed", AuditStage: "not-started", ContextState: state, DeadlineExceeded: state == "deadline"}
			}
			failure.CallPhase, failure.CallMilliseconds, failure.PhaseTimings = timing.finish()
			resultErr = failure
		}
	}()
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
	timing.mark("initial-selection")
	if err := validateSelection(); err != nil {
		return empty, err
	}
	var snapshot NativeConfigurationSnapshot
	storage, err := observeNativeStorageTimed(ctx, func() error {
		var readErr error
		snapshot, readErr = readNativeConfigurationTimed(ctx, roots, selectedRoot, selectedFound, func(root string) error {
			previous := timing.phase
			timing.mark("metadata-root-audit")
			volume := filepath.VolumeName(root)
			if len(volume) != 2 || volume[1] != ':' || filepath.Clean(root) != volume+`\wootc` {
				return fmt.Errorf("invalid configuration location")
			}
			if err := inspectStateObject(volume+`\`, true); err != nil {
				return err
			}
			err := auditNativeStatusTree(ctx, root, 4096, func(path string) error { return inspectStateObject(path, false) })
			if err == nil {
				timing.mark(previous)
			}
			return err
		}, timing.mark)
		return readErr
	}, timing.mark)
	if err != nil {
		return empty, err
	}
	timing.mark("final-selection")
	if err := validateSelection(); err != nil {
		return empty, err
	}
	snapshot.StorageStatus, snapshot.Storage = "observed", storage
	return snapshot, nil
}
