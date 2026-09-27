package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Actual inherited-pipe child, not a VM. It exercises production QMP/capture
// consumers but cannot establish guest or desktop acceptance.
func TestVMDisplayChild(t *testing.T) {
	mode := os.Getenv("WOOTC_DISPLAY_CHILD")
	if mode == "" {
		return
	}
	fmt.Println(`{"QMP":{"version":{},"capabilities":[]}}`)
	r := bufio.NewScanner(os.Stdin)
	for r.Scan() {
		var req struct {
			Execute string          `json:"execute"`
			ID      string          `json:"id"`
			Args    json.RawMessage `json:"arguments"`
		}
		if json.Unmarshal(r.Bytes(), &req) != nil {
			os.Exit(9)
		}
		if path := os.Getenv("WOOTC_DISPLAY_SPY"); path != "" {
			f, e := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
			if e != nil {
				os.Exit(8)
			}
			fmt.Fprintln(f, req.Execute)
			f.Close()
		}
		value := `{}`
		switch req.Execute {
		case "query-status":
			if mode == "slow" {
				time.Sleep(120 * time.Millisecond)
			}
			value = `{"running":true,"singlestep":false,"status":"running"}`
			if mode == "paused" {
				value = `{"running":false,"singlestep":false,"status":"paused"}`
			}
			if mode == "fake-status" {
				value = `{"running":"true","singlestep":false,"status":"running"}`
			}
		case "query-mice":
			value = `[{"name":"mouse","index":0,"current":true,"absolute":false}]`
			if mode == "ambiguous-mice" {
				value = `[{"name":"a","index":0,"current":true,"absolute":false},{"name":"b","index":1,"current":true,"absolute":true}]`
			}
		case "screendump":
			var args struct {
				Filename string `json:"filename"`
			}
			if json.Unmarshal(req.Args, &args) != nil {
				os.Exit(7)
			}
			data := []byte("P6\n1 1\n255\nRGB")
			if mode == "bad-pixels" {
				data = []byte("P6\n1 1\n255\nR")
			}
			if mode != "missing-capture" {
				if os.WriteFile(args.Filename, data, 0600) != nil {
					os.Exit(6)
				}
			}
		case "input-send-event":
			var args struct {
				Events []json.RawMessage `json:"events"`
			}
			if json.Unmarshal(req.Args, &args) != nil || len(args.Events) == 0 {
				os.Exit(5)
			}
			if mode == "bad-key-ack" {
				value = `{"delivered":true}`
			}
		}
		fmt.Printf("{\"return\":%s,\"id\":%q}\n", value, req.ID)
		if req.Execute == "system_powerdown" && mode != "hung-powerdown" {
			fmt.Println(`{"event":"SHUTDOWN","data":{"guest":true,"reason":"guest-shutdown"}}`)
			os.Exit(0)
		}
	}
	os.Exit(0)
}
func displaySession(t *testing.T, mode string) (*vmSession, vmDisplayRequest, string) {
	t.Helper()
	dir := t.TempDir()
	spy := filepath.Join(dir, "spy")
	cmd := exec.Command(os.Args[0], "-test.run=^TestVMDisplayChild$")
	cmd.Env = append(os.Environ(), "WOOTC_DISPLAY_CHILD="+mode, "WOOTC_DISPLAY_SPY="+spy)
	state := VMState{RunID: "run", InstallID: "install", DiskID: "gpt", DiskPath: filepath.Join(dir, "root.disk"), Phase: vmReady}
	s, err := startManagedVM(cmd, filepath.Join(dir, "state.json"), state, func() {}, func(*exec.Cmd) (io.Closer, error) { return noopVMJob{}, nil })
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.force() })
	req := vmDisplayRequest{RunID: "run", InstallID: "install", DiskID: "gpt", SessionID: s.sessionID, DirectiveID: strings.Repeat("a", 32), Action: "status"}
	return s, req, spy
}
func TestVMDisplayActionsAndSessionNonce(t *testing.T) {
	s, req, _ := displaySession(t, "normal")
	other, _, _ := displaySession(t, "normal")
	if s.sessionID == other.sessionID || !validDisplayDirective(s.sessionID) {
		t.Fatal("session nonce was reused")
	}
	for i, action := range []string{"status", "mice", "keys", "capture"} {
		req.Action = action
		req.DirectiveID = fmt.Sprintf("%032x", i+1)
		req.Keys = nil
		if action == "keys" {
			req.Keys = []vmDisplayKey{{"ctrl", true}, {"s", true}, {"s", false}, {"ctrl", false}}
		}
		out, err := s.observeDisplay(context.Background(), req)
		if err != nil {
			t.Fatal(action, err)
		}
		if !out.Running || out.DesktopQualified || out.SessionID != s.sessionID {
			t.Fatal("QMP observation became desktop qualification or lost identity")
		}
		if action == "capture" {
			if out.Width != 1 || out.Height != 1 || len(out.CaptureSHA256) != 64 {
				t.Fatal("unverified capture")
			}
			if !strings.HasPrefix(out.CapturePath, filepath.Dir(s.statePath)+string(os.PathSeparator)) {
				t.Fatal("capture escaped owned directory")
			}
		}
	}
	if s.snapshot().DesktopReady {
		t.Fatal("desktopReady became true")
	}
}
func TestVMDisplayIdentityAndReplayRefuseBeforeGuest(t *testing.T) {
	s, req, spy := displaySession(t, "normal")
	before, _ := os.ReadFile(spy)
	for _, which := range []string{"run", "install", "disk", "session", "directive", "arbitrary-action"} {
		bad := req
		switch which {
		case "run":
			bad.RunID = "old"
		case "install":
			bad.InstallID = "old"
		case "disk":
			bad.DiskID = "old"
		case "session":
			bad.SessionID = "old"
		case "directive":
			bad.DirectiveID = "../escape"
		case "arbitrary-action":
			bad.Action = "human-monitor-command"
		}
		if _, err := s.observeDisplay(context.Background(), bad); err == nil {
			t.Fatal(which, "accepted")
		}
	}
	after, _ := os.ReadFile(spy)
	if string(after) != string(before) {
		t.Fatal("refused identity reached guest")
	}
	if _, err := s.observeDisplay(context.Background(), req); err != nil {
		t.Fatal(err)
	}
	before, _ = os.ReadFile(spy)
	if _, err := s.observeDisplay(context.Background(), req); err == nil {
		t.Fatal("directive replay accepted")
	}
	after, _ = os.ReadFile(spy)
	if string(after) != string(before) {
		t.Fatal("replay reached guest")
	}
}
func TestVMDisplayUnknownOrFailedObservations(t *testing.T) {
	for _, mode := range []string{"paused", "fake-status", "ambiguous-mice", "bad-pixels", "missing-capture", "bad-key-ack"} {
		t.Run(mode, func(t *testing.T) {
			s, req, _ := displaySession(t, mode)
			switch mode {
			case "ambiguous-mice":
				req.Action = "mice"
			case "bad-pixels", "missing-capture":
				req.Action = "capture"
			case "bad-key-ack":
				req.Action = "keys"
				req.Keys = []vmDisplayKey{{"a", true}, {"a", false}}
			}
			if out, err := s.observeDisplay(context.Background(), req); err == nil || out.DesktopQualified {
				t.Fatal("failed observation accepted")
			}
		})
	}
}
func TestVMDisplayKeyValidation(t *testing.T) {
	for _, keys := range [][]vmDisplayKey{nil, {{"a", true}}, {{"a", false}}, {{"a", true}, {"a", true}}, {{"human-monitor-command", true}, {"human-monitor-command", false}}, make([]vmDisplayKey, 65)} {
		if _, err := displayKeyEvents(keys); err == nil {
			t.Fatal("invalid key batch accepted")
		}
	}
}
func TestVMDisplayDeadlineAndLifecycle(t *testing.T) {
	s, req, _ := displaySession(t, "slow")
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := s.observeDisplay(ctx, req); err == nil {
		t.Fatal("blocking operation passed")
	}
	if time.Since(start) > 500*time.Millisecond {
		t.Fatal("whole display deadline exceeded")
	}
	// Gate contention itself must honor the caller's deadline, without guest I/O.
	s.operationGate <- struct{}{}
	req.DirectiveID = strings.Repeat("b", 32)
	ctx2, cancel2 := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel2()
	if _, err := s.observeDisplay(ctx2, req); err == nil {
		t.Fatal("gate contention passed")
	}
	s.releaseOperation()
	s.mu.Lock()
	s.state.Phase = vmStopping
	s.mu.Unlock()
	if _, err := s.observeDisplay(context.Background(), req); err == nil {
		t.Fatal("stop/input race accepted")
	}
}
func TestVMDisplaySymlinkCaptureParentRefused(t *testing.T) {
	s, req, _ := displaySession(t, "normal")
	dir := t.TempDir()
	link := filepath.Join(dir, "link")
	if err := os.Symlink(filepath.Dir(s.statePath), link); err != nil {
		t.Skip(err)
	}
	s.statePath = filepath.Join(link, "state.json")
	req.Action = "capture"
	if _, err := s.observeDisplay(context.Background(), req); err == nil {
		t.Fatal("symlink parent accepted")
	}
}

func TestVMDisplayEngineOwnerAndChangedSession(t *testing.T) {
	s, req, _ := displaySession(t, "normal")
	a := &App{}
	if _, err := a.observeVMDisplay(context.Background(), req); err == nil {
		t.Fatal("unowned session accepted")
	}
	a.vmSession = s
	if out, err := a.observeVMDisplay(context.Background(), req); err != nil || out.DesktopQualified {
		t.Fatal("engine route failed or qualified desktop", err)
	}
}

func TestVMDisplayForceRemainsAvailableDuringShutdownWait(t *testing.T) {
	s, req, spy := displaySession(t, "hung-powerdown")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	stopped := make(chan error, 1)
	go func() { stopped <- s.stop(ctx) }()
	deadline := time.Now().Add(time.Second)
	for {
		data, _ := os.ReadFile(spy)
		if strings.Contains(string(data), "system_powerdown") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("shutdown request never observed")
		}
		time.Sleep(time.Millisecond)
	}
	if _, err := s.observeDisplay(context.Background(), req); err == nil {
		t.Fatal("input accepted during shutdown")
	}
	start := time.Now()
	if err := s.force(); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) > time.Second {
		t.Fatal("force stop blocked behind guest shutdown wait")
	}
	if err := <-stopped; err == nil {
		t.Fatal("forced stop became clean guest shutdown")
	}
	if s.snapshot().Phase != vmRecovery {
		t.Fatal("forced stop lost recovery state")
	}
}
