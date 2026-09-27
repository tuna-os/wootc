//go:build windows

package main

import (
	"os"
	"os/exec"
	"regexp"
	"strings"
	"testing"
)

func TestNTFSHostUUIDMatchesNativeVolume(t *testing.T) {
	drive := strings.TrimSuffix(os.Getenv("SystemDrive"), ":")
	actual, err := ntfsHostUUID(drive)
	if err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("fsutil.exe", "fsinfo", "ntfsinfo", drive+":").CombinedOutput()
	if err != nil {
		t.Fatalf("fsutil: %v %s", err, out)
	}
	// The first NTFS info field carries the serial, independent of label locale.
	match := regexp.MustCompile(`(?i)0x([0-9a-f]{16})`).FindSubmatch(out)
	if len(match) != 2 || !strings.EqualFold(actual, string(match[1])) {
		t.Fatalf("full NTFS UUID %s does not match fsutil's serial", actual)
	}
	if _, err := ntfsHostUUID("C:\\"); err == nil {
		t.Fatal("accepted an invalid drive selector")
	}
}
