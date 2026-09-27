package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVMAccountInputIsPrivateTransientAndPreservesDisk(t *testing.T) {
	root := t.TempDir()
	disk := filepath.Join(root, "root.disk")
	if err := os.WriteFile(disk, []byte("existing Linux files"), 0600); err != nil {
		t.Fatal(err)
	}
	input := vmAccountInput{SchemaVersion: 1, RunID: "run-12345", InstallID: "install-12345", Username: "alice", PasswordHash: "$6$test$hash"}
	path, err := writeVMAccountInput(root, input)
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var got vmAccountInput
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatal(err)
	}
	if got != input {
		t.Fatalf("private input changed: %+v", got)
	}
	if _, err := writeVMAccountInput(root, input); err == nil {
		t.Fatal("existing account input overwritten")
	}
	if err := removeVMAccountInputs(root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("stale account input survived cleanup")
	}
	data, err = os.ReadFile(disk)
	if err != nil || string(data) != "existing Linux files" {
		t.Fatal("credential cleanup damaged disk")
	}
}
func TestVMAccountValidationDoesNotEchoPassword(t *testing.T) {
	base := VMInstallConfig{ImageRef: "ghcr.io/test/os:latest", Username: "alice", Password: "private\nsecret"}
	for _, which := range []string{"password", "root", "traversal", "image"} {
		cfg := base
		switch which {
		case "root":
			cfg.Username = "root"
		case "traversal":
			cfg.Username = "../alice"
		case "image":
			cfg.ImageRef = "image wootc.inject=yes"
		}
		err := validateVMInstallConfig(cfg)
		if err == nil {
			t.Errorf("accepted %s", which)
		} else if strings.Contains(err.Error(), "private") {
			t.Fatal("error leaked password")
		}
	}
	base.Password = "a valid password"
	if err := validateVMInstallConfig(base); err != nil {
		t.Fatal(err)
	}
}
func TestVMReceiptRequiresCreatedAccountIdentity(t *testing.T) {
	path, id := vmTestDisk(t)
	state := VMState{RunID: "run-12345", InstallID: "install-12345", Image: "image@digest", DiskPath: path, Username: "alice", AccountOutcome: "created"}
	receipt := vmBuilderReceipt{Type: "result", SchemaVersion: 1, Status: "success", RunID: state.RunID, InstallID: state.InstallID, Image: state.Image, DiskID: id, FilesystemVerified: true, EFIVerified: true, AccountOutcome: "created", Username: "alice"}
	check := func(receipt vmBuilderReceipt) error {
		data, _ := json.Marshal(receipt)
		_, err := verifyVMBuilderReceipt(strings.NewReader(string(data)+"\nSTATUS=SUCCESS\n"), state)
		return err
	}
	if err := check(receipt); err != nil {
		t.Fatal(err)
	}
	receipt.Username = "another"
	if check(receipt) == nil {
		t.Fatal("another account accepted")
	}
	receipt.Username = "alice"
	receipt.AccountOutcome = "image-default"
	if check(receipt) == nil {
		t.Fatal("unpersonalized image accepted")
	}
}
