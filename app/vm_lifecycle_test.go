package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func vmTestDisk(t *testing.T) (string, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "root.disk")
	data := make([]byte, 1024)
	copy(data[512:], "EFI PART")
	copy(data[568:], []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16})
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	id, err := vmDiskIdentity(path)
	if err != nil {
		t.Fatal(err)
	}
	return path, id
}
func TestVMReceiptRejectsProxySuccess(t *testing.T) {
	path, id := vmTestDisk(t)
	state := VMState{RunID: "run-12345", InstallID: "install-123", Image: "repo@sha256:abc", DiskPath: path}
	good := vmBuilderReceipt{Type: "result", SchemaVersion: 1, Status: "success", RunID: state.RunID, InstallID: state.InstallID, Image: state.Image, DiskID: id, FilesystemVerified: true, EFIVerified: true, AccountOutcome: "image-default"}
	for _, which := range []string{"good", "only-marker", "wrong-run", "wrong-image", "wrong-disk", "no-efi", "duplicate", "late-error", "early-marker"} {
		t.Run(which, func(t *testing.T) {
			receipt := good
			switch which {
			case "wrong-run":
				receipt.RunID = "another-run"
			case "wrong-image":
				receipt.Image = "another-image"
			case "wrong-disk":
				receipt.DiskID = "another-disk"
			case "no-efi":
				receipt.EFIVerified = false
			}
			data, _ := json.Marshal(receipt)
			log := string(data) + "\nSTATUS=SUCCESS\n"
			switch which {
			case "only-marker":
				log = "STATUS=SUCCESS\n"
			case "duplicate":
				log += string(data) + "\n"
			case "late-error":
				log += "{\"step\":\"error\"}\n"
			case "early-marker":
				log = "STATUS=SUCCESS\n" + string(data) + "\n"
			}
			_, err := verifyVMBuilderReceipt(strings.NewReader(log), state)
			if (err == nil) != (which == "good") {
				t.Fatalf("verification error = %v", err)
			}
		})
	}
}
func TestVMDurableStateAndNativeWriterGuard(t *testing.T) {
	root := t.TempDir()
	path, id := vmTestDisk(t)
	state := VMState{InstallID: "install-123", RunID: "run-12345", DiskPath: path, DiskID: id, Phase: vmStopped, DesktopReady: true}
	if err := writeVMState(vmStatePath(root), state); err != nil {
		t.Fatal(err)
	}
	got, err := readVMState(vmStatePath(root))
	if err != nil {
		t.Fatal(err)
	}
	if got.DesktopReady {
		t.Fatal("durable state claims desktop without guest evidence")
	}
	if err := vmLaunchAllowed(got, path); err != nil {
		t.Fatal(err)
	}
	for _, phase := range []string{vmPreparing, vmRunning, vmStarting, vmStopping, vmRecovery, vmFailed} {
		got.Phase = phase
		if vmLaunchAllowed(got, path) == nil {
			t.Errorf("launched %s", phase)
		}
	}
	if release, err := acquireNativeInstallLease(root); err == nil {
		release()
		t.Fatal("native redeploy accepted managed image")
	}
	got.Phase = vmStopped
	got.DiskID = "different"
	if vmLaunchAllowed(got, path) == nil {
		t.Fatal("changed disk accepted")
	}
}
