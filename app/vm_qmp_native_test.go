package main

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestQMPNativePausedComponent(t *testing.T) {
	binary, err := exec.LookPath("qemu-system-x86_64")
	if err != nil {
		if os.Getenv("WOOTC_REQUIRE_NATIVE_QMP") == "1" {
			t.Fatal(err)
		}
		t.Skip("native QEMU unavailable; no native protocol proof")
	}
	version, err := exec.Command(binary, "--version").Output()
	if err != nil {
		t.Fatal(err)
	}
	t.Log(strings.TrimSpace(string(version)))
	root := t.TempDir()
	cmd := exec.Command(binary, "-no-user-config", "-machine", "q35", "-accel", "tcg", "-S", "-m", "128", "-nodefaults", "-device", "VGA", "-display", "none", "-nic", "none", "-qmp", "stdio", "-monitor", "none")
	state := VMState{RunID: "component", InstallID: "component", DiskID: "none-attached", DiskPath: filepath.Join(root, "unused"), Phase: vmReady}
	s, err := startManagedVM(cmd, filepath.Join(root, "state.json"), state, func() {}, func(*exec.Cmd) (io.Closer, error) { return noopVMJob{}, nil })
	if err != nil {
		t.Fatal(err)
	}
	defer s.force()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	raw, err := s.qmp.request(ctx, "query-status", nil)
	if err != nil {
		t.Fatal(err)
	}
	var status struct {
		Running bool   `json:"running"`
		Status  string `json:"status"`
	}
	if json.Unmarshal(raw, &status) != nil || status.Running || status.Status == "running" {
		t.Fatal("paused component incorrectly running", string(raw))
	}
	t.Log("actual paused status", string(raw))
	req := vmDisplayRequest{RunID: state.RunID, InstallID: state.InstallID, DiskID: state.DiskID, SessionID: s.sessionID, DirectiveID: strings.Repeat("c", 32), Action: "keys", Keys: []vmDisplayKey{{"a", true}, {"a", false}}}
	if _, err = s.observeDisplay(ctx, req); err == nil {
		t.Fatal("paused component accepted scoped input")
	}
	path, hash, width, height, err := s.captureDisplay(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if hash == "" || width < 1 || height < 1 || !strings.HasPrefix(path, root) {
		t.Fatal("native capture not verified")
	}
	t.Logf("actual native PPM %dx%d sha256=%s", width, height, hash)
	if _, err = s.qmp.request(ctx, "screendump", map[string]string{"filename": root}); err == nil {
		t.Fatal("actual native failed capture accepted")
	}
	if s.snapshot().DesktopReady {
		t.Fatal("native paused component became desktop ready")
	}
}
