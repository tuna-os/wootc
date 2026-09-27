package main

import (
	"context"
	"fmt"
	"time"
)

const vmWindowsReserveBytes = uint64(8) << 30

// An admission check cannot reserve free space against other Windows apps.
// Recheck while the helper writes, and retain the cancellation cause for the UI.
func guardVMFreeSpace(parent context.Context, minimum uint64, interval time.Duration, sample func() (uint64, error)) (context.Context, func()) {
	ctx, cancel := context.WithCancelCause(parent)
	done := make(chan struct{})
	go func() {
		defer close(done)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			available, err := sample()
			if err != nil {
				cancel(fmt.Errorf("could not check the space reserved for Windows: %w", err))
				return
			}
			if available < minimum {
				cancel(fmt.Errorf("preparation stopped because Windows free space fell below the 8 GB reserve; free more space before trying again"))
				return
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	return ctx, func() { cancel(nil); <-done }
}
