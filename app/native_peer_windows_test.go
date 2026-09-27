//go:build windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func TestNativePeerObservationUsesActualProcessIdentity(t *testing.T) {
	peer, err := observeNativeProcessPeer(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	defer peer.close()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.EqualFold(filepath.Clean(peer.imagePath), filepath.Clean(executable)) {
		t.Fatalf("observed image %q differs from executable %q", peer.imagePath, executable)
	}
	token, err := windows.OpenCurrentProcessToken()
	if err != nil {
		t.Fatal(err)
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	if peer.userSID != user.User.Sid.String() {
		t.Fatal("observed peer user differs from actual process token")
	}
	if err := peer.checkAlive(); err != nil {
		t.Fatal(err)
	}
	peer.close()
	if err := peer.checkAlive(); err == nil {
		t.Fatal("closed process handle accepted")
	}
}

func TestNativePeerObservationRejectsMissingOrUnknownProcess(t *testing.T) {
	for _, pid := range []uint32{0, 0xffffffff} {
		peer, err := observeNativeProcessPeer(pid)
		if err == nil {
			peer.close()
			t.Fatalf("unknown process %d accepted", pid)
		}
	}
}
