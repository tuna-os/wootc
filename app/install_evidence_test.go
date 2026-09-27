package main

import (
	"os"
	"path/filepath"
	"testing"
)

func stageEvidenceFixture(t *testing.T, root, relative string) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(relative))
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestInstallEvidenceAllowsFirstOfflineLaunch(t *testing.T) {
	root := filepath.Join(t.TempDir(), "wootc")
	if hasInstallAttempt(root) {
		t.Fatal("absent state is an install attempt")
	}
	if err := os.MkdirAll(filepath.Join(root, "logs"), 0700); err != nil {
		t.Fatal(err)
	}
	if hasInstallAttempt(root) {
		t.Fatal("empty reservation/log directory is an install attempt")
	}
	for _, file := range []string{
		"wootc.exe", "launch-gui.cmd", "brand.json", "brand.css", "channel.txt", "images.json",
		"e2e-drive.json", "e2e-drive-state.json", "install/SHA256SUMS", "install/deployer-vmlinuz",
		"install/deployer-initramfs.img", "install/shimx64.efi", "install/grubx64.efi",
		"install/mmx64.efi", "install/wubildr.efi", "install/mirror.txt", "bundle/oci/index.json",
	} {
		stageEvidenceFixture(t, root, file)
	}
	if hasInstallAttempt(root) {
		t.Fatal("offline/GUI payload routed a first launch to the Control Panel")
	}
	// The first recorded preparation changes the result even with every
	// provisioning artifact still present. It must not be mistaken for a bundle.
	stageEvidenceFixture(t, root, "install/prior-power.txt")
	if !hasInstallAttempt(root) {
		t.Fatal("Windows preparation was hidden by offline payloads")
	}
}

func TestInstallEvidencePreservesInterruptedAttempts(t *testing.T) {
	for _, evidence := range []string{
		"state.json", "known-folders.json", "disks/root.disk", "disks/root.vhdx",
		"install/prior-power.txt", "install/vault.json", "install/grub.install.cfg",
		"install/bcd-before.bak", "install/bcd-guid.txt", "install/armed.json",
		"install/deployer-started.json", "install/recovery-verdict.json",
		"logs/deployer.log", "logs/deployer-last-journal.log",
	} {
		t.Run(evidence, func(t *testing.T) {
			root := t.TempDir()
			stageEvidenceFixture(t, root, evidence)
			if !hasInstallAttempt(root) {
				t.Fatal("interrupted installation was hidden")
			}
		})
	}
}
