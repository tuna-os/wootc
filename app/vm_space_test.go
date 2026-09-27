package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestVMFreeSpaceGuardObservesDropAndJoins(t *testing.T) {
	samples := make(chan uint64, 2)
	samples <- 200
	samples <- 50
	observed := make(chan uint64, 2)
	ctx, stop := guardVMFreeSpace(context.Background(), 100, time.Millisecond, func() (uint64, error) { value := <-samples; observed <- value; return value, nil })
	defer stop()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("low space never stopped preparation")
	}
	if <-observed != 200 || <-observed != 50 {
		t.Fatal("guard did not observe changing free space")
	}
	if !strings.Contains(context.Cause(ctx).Error(), "reserve") {
		t.Fatal(context.Cause(ctx))
	}
}
func TestVMFreeSpaceGuardStopsWithParent(t *testing.T) {
	parent, cancel := context.WithCancel(context.Background())
	observed := make(chan struct{}, 1)
	_, stop := guardVMFreeSpace(parent, 100, time.Hour, func() (uint64, error) { observed <- struct{}{}; return 200, nil })
	<-observed
	cancel()
	done := make(chan struct{})
	go func() { stop(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("space monitor outlived its worker")
	}
}
