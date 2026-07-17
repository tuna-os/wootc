package main

import (
	"context"
	"sync"
	"testing"
)

// TestStatusConcurrentAccess exercises the status mutex: concurrent GetStatus
// polling (as the frontend does on a timer) against status writers must be
// race-free under `go test -race`.
func TestStatusConcurrentAccess(t *testing.T) {
	a := NewApp()
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(3)
		go func() { defer wg.Done(); _ = a.GetStatus() }()
		go func() { defer wg.Done(); a.mutateStatus(func(s *InstallStatus) { s.Running = !s.Running }) }()
		go func() { defer wg.Done(); a.setStatus(InstallStatus{Done: true}) }()
	}
	wg.Wait()
}

// TestStartInstallRejectsConcurrent verifies the atomic claim: a second
// StartInstall while one is Running is rejected.
func TestStartInstallRejectsConcurrent(t *testing.T) {
	a := NewApp()
	a.ctx = context.Background()
	a.setStatus(InstallStatus{Running: true})
	if err := a.StartInstall(InstallConfig{Bootloader: "grub2", Encryption: "none"}); err == nil {
		t.Fatal("expected rejection while an install is running")
	}
}

// TestGetImagesEmbedded verifies the embedded catalog parses and is non-empty.
func TestGetImagesEmbedded(t *testing.T) {
	a := NewApp()
	imgs, err := a.GetImages()
	if err != nil {
		t.Fatalf("GetImages: %v", err)
	}
	if len(imgs) == 0 {
		t.Fatal("embedded catalog is empty")
	}
	for _, im := range imgs {
		if im.ImageRef == "" || im.ID == "" {
			t.Fatalf("catalog entry missing fields: %+v", im)
		}
	}
}
