//go:build !windows

package main

import "fmt"

// VMCapability mirrors the Windows type so the frontend bindings are stable
// across platforms.
type VMCapability struct {
	Available   bool   `json:"available"`
	Reason      string `json:"reason"`
	DiskPath    string `json:"diskPath"`
	Accelerator string `json:"accelerator"`
	QEMUPath    string `json:"qemuPath"`
	Bundled     bool   `json:"bundled"`
}

func (a *App) GetVMCapability() VMCapability {
	return VMCapability{Available: false, Reason: "The VM viewer is only available on Windows."}
}

func (a *App) BootInVM() error {
	return fmt.Errorf("the VM viewer is only available on Windows")
}
