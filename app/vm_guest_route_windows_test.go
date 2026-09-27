//go:build windows

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"golang.org/x/sys/windows"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// Real private Win32 pipe/process fixture. Only reply observations are synthetic;
// there is no QEMU, Linux image, desktop, account or service installation.
func vmGuestPersistentPipeChild(t *testing.T, handle windows.Handle, mode string) {
	t.Helper()
	first := ""
	for index := 0; index < 128; index++ {
		input := []byte{}
		for len(input) < 4096 {
			buffer := make([]byte, 1)
			var n uint32
			if err := windows.ReadFile(handle, buffer, &n, nil); err != nil {
				return
			}
			input = append(input, buffer[:n]...)
			if n == 1 && buffer[0] == '\n' {
				break
			}
		}
		var req vmGuestProbeRequest
		if err := json.Unmarshal(input, &req); err != nil {
			t.Fatal(err)
		}
		if first == "" {
			first = req.RequestID
		}
		if index == 1 && mode == "persistent-stall" {
			time.Sleep(5 * time.Second)
			return
		}
		var reply map[string]any
		if err := json.Unmarshal([]byte(os.Getenv("WOOTC_VM_PIPE_REPLY")), &reply); err != nil {
			t.Fatal(err)
		}
		reply["requestId"] = req.RequestID
		if index == 1 && mode == "persistent-replay" {
			reply["requestId"] = first
		}
		if index == 1 && mode == "persistent-foreign" {
			reply["sessionId"] = strings.Repeat("f", 32)
		}
		raw, err := json.Marshal(reply)
		if err != nil {
			t.Fatal(err)
		}
		raw = append(raw, '\n')
		var written uint32
		if err = windows.WriteFile(handle, raw, &written, nil); err != nil {
			return
		}
		if int(written) != len(raw) {
			t.Fatal("fixture short write")
		}
	}
}

func TestVMGuestWindowsPersistentRoute(t *testing.T) {
	for _, mode := range []string{"persistent-success", "persistent-replay", "persistent-foreign", "persistent-stall"} {
		t.Run(mode, func(t *testing.T) {
			req, reply := guestProbeFixture()
			nonce, err := freshVMSessionID()
			if err != nil {
				t.Fatal(err)
			}
			req.SessionID = nonce
			reply["sessionId"] = nonce
			peer, cleanup := vmGuestWindowsFixture(t, req, reply, mode)
			defer cleanup()
			process, err := os.FindProcess(int(peer.pid))
			if err != nil {
				t.Fatal(err)
			}
			transport, err := ownVMGuestObserver(&exec.Cmd{Path: peer.imagePath, Process: process}, true)
			if err != nil {
				t.Fatal(err)
			}
			native := transport.(*nativeVMGuestTransport)
			defer native.close()
			first, err := native.observe(context.Background(), req)
			if err != nil || first.RequestID != req.RequestID {
				t.Fatalf("first actual exchange %v %v", first, err)
			}
			retained := native.connection
			if retained == nil {
				t.Fatal("successful connection not retained")
			}
			if native.peer.handle == 0 || native.peer.checkAlive() != nil {
				t.Fatal("owned live peer not retained")
			}
			req.RequestID = strings.Repeat("e", 32)
			ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
			defer cancel()
			started := time.Now()
			second, err := native.observe(ctx, req)
			if mode != "persistent-success" {
				if err == nil {
					t.Fatal("foreign/replayed/stalled actual pipe accepted")
				}
				if time.Since(started) > time.Second {
					t.Fatal("original short deadline replaced")
				}
				if !native.closed || native.connection != nil {
					t.Fatal("failed channel not retired")
				}
				req.RequestID = strings.Repeat("d", 32)
				if _, err = native.observe(context.Background(), req); err == nil || native.connection != nil {
					t.Fatal("failed session reopened")
				}
				fmt.Println("PERSISTENT-REFUSAL", mode, "NO-REOPEN")
				return
			}
			if err != nil || second.RequestID != req.RequestID || native.connection != retained {
				t.Fatalf("second request did not preserve duplex channel %v", err)
			}
			if _, err = native.observe(context.Background(), req); err == nil {
				t.Fatal("duplicate request emitted")
			}
			if err = process.Kill(); err != nil {
				t.Fatal(err)
			}
			wait, err := windows.WaitForSingleObject(native.peer.handle, 1000)
			if err != nil || wait != windows.WAIT_OBJECT_0 {
				t.Fatalf("owned server not actually reaped/dead %v %v", wait, err)
			}
			cleanup() // Actual fixture parent Wait completes; the route retains its own handle.
			if native.peer.handle == 0 {
				t.Fatal("route peer released before parent cleanup")
			}
			fmt.Println("PERSISTENT-OWNED-SERVER-DEAD", peer.pid)
			req.RequestID = strings.Repeat("d", 32)
			if _, err = native.observe(context.Background(), req); err == nil || !native.closed {
				t.Fatal("dead retained server accepted")
			}
		})
	}
}
func TestVMGuestWindowsConfigureOwnedArgs(t *testing.T) {
	s, _ := routeFixture(t)
	cmd := exec.Command(os.Args[0], "original")
	enabled, err := configureVMGuestChannel(cmd, s.state, s.sessionID)
	if err != nil || !enabled || len(cmd.Args) != 8 || cmd.Args[1] != "original" {
		t.Fatalf("fixed argv not composed %v %v", cmd.Args, err)
	}
	if _, err = ownVMGuestObserver(&exec.Cmd{}, true); err == nil {
		t.Fatal("unlaunched process accepted")
	}
}

func TestVMGuestWindowsPersistentConcurrentDeadline(t *testing.T) {
	req, reply := guestProbeFixture()
	nonce, err := freshVMSessionID()
	if err != nil {
		t.Fatal(err)
	}
	req.SessionID = nonce
	reply["sessionId"] = nonce
	peer, cleanup := vmGuestWindowsFixture(t, req, reply, "blocked-read")
	defer cleanup()
	process, err := os.FindProcess(int(peer.pid))
	if err != nil {
		t.Fatal(err)
	}
	route, err := ownVMGuestObserver(&exec.Cmd{Path: peer.imagePath, Process: process}, true)
	if err != nil {
		t.Fatal(err)
	}
	native := route.(*nativeVMGuestTransport)
	defer native.close()
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	finished := make(chan error, 1)
	go func() { _, err := native.observe(ctx, req); finished <- err }()
	deadline := time.Now().Add(200 * time.Millisecond)
	for native.mu.TryLock() {
		native.mu.Unlock()
		if time.Now().After(deadline) {
			t.Fatal("first actual call did not acquire owned gate")
		}
		time.Sleep(time.Millisecond)
	}
	second, cancelSecond := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancelSecond()
	started := time.Now()
	req.RequestID = strings.Repeat("e", 32)
	if _, err = native.observe(second, req); err == nil || time.Since(started) > 200*time.Millisecond {
		t.Fatalf("original concurrent deadline not honored %v", err)
	}
	select {
	case err := <-finished:
		if err == nil {
			t.Fatal("blocked first call accepted")
		}
	case <-time.After(time.Second):
		t.Fatal("blocked first call exceeded bound")
	}
	if !native.closed || native.connection != nil {
		t.Fatal("timed-out channel retained")
	}
}
