//go:build windows

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

// Disposable Win32 IPC fixture only. No QEMU, guest or desktop acceptance.
func TestVMGuestPipeChild(t *testing.T) {
	if os.Getenv("WOOTC_VM_PIPE_CHILD") != "1" {
		return
	}
	name := os.Getenv("WOOTC_VM_PIPE_NAME")
	path, err := windows.UTF16PtrFromString(name)
	if err != nil {
		t.Fatal(err)
	}
	handle, err := windows.CreateNamedPipe(path, windows.PIPE_ACCESS_DUPLEX|windows.FILE_FLAG_FIRST_PIPE_INSTANCE,
		windows.PIPE_TYPE_BYTE|windows.PIPE_READMODE_BYTE|windows.PIPE_WAIT|windows.PIPE_REJECT_REMOTE_CLIENTS, 1, 4096, 4096, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(handle)
	fmt.Println("PIPE-READY")
	if err = windows.ConnectNamedPipe(handle, nil); err != nil && err != windows.ERROR_PIPE_CONNECTED {
		t.Fatal(err)
	}
	if os.Getenv("WOOTC_VM_PIPE_MODE") == "death" {
		return
	}
	input := []byte{}
	for len(input) < 4096 {
		buffer := make([]byte, 1)
		var read uint32
		if err = windows.ReadFile(handle, buffer, &read, nil); err != nil {
			if os.Getenv("WOOTC_VM_PIPE_MODE") == "foreign-peer" {
				return
			}
			t.Fatal(err)
		}
		input = append(input, buffer[:read]...)
		if read == 1 && buffer[0] == '\n' {
			break
		}
	}
	if os.Getenv("WOOTC_VM_PIPE_MODE") == "blocked-read" {
		time.Sleep(5 * time.Second)
		return
	}
	payload := []byte(os.Getenv("WOOTC_VM_PIPE_REPLY") + "\n")
	var written uint32
	if err = windows.WriteFile(handle, payload, &written, nil); err != nil {
		t.Fatal(err)
	}
	if int(written) != len(payload) {
		t.Fatal("short fixture reply")
	}
	time.Sleep(2 * time.Second)
}
func vmGuestWindowsFixture(t *testing.T, req vmGuestProbeRequest, reply map[string]any, mode string) (*nativeProcessPeer, func()) {
	t.Helper()
	name, err := vmGuestPipeName(req.SessionID)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(reply)
	cmd := exec.Command(os.Args[0], "-test.run=^TestVMGuestPipeChild$", "-test.count=1")
	cmd.Env = append(os.Environ(), "WOOTC_VM_PIPE_CHILD=1", "WOOTC_VM_PIPE_NAME="+name, "WOOTC_VM_PIPE_MODE="+mode, "WOOTC_VM_PIPE_REPLY="+string(raw))
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	cmd.Stderr = os.Stderr
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	cleanup := func() { _ = cmd.Process.Kill(); _ = cmd.Wait(); _ = stdout.Close() }
	ready := make(chan bool, 1)
	go func() {
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			if scanner.Text() == "PIPE-READY" {
				ready <- true
				return
			}
		}
		ready <- false
	}()
	select {
	case yes := <-ready:
		if !yes {
			cleanup()
			t.Fatal("fixture pipe not ready")
		}
	case <-time.After(5 * time.Second):
		cleanup()
		t.Fatal("fixture startup deadline")
	}
	peer, err := observeNativeProcessPeer(uint32(cmd.Process.Pid))
	if err != nil {
		cleanup()
		t.Fatal(err)
	}
	return peer, func() { peer.close(); cleanup() }
}
func TestVMGuestWindowsPipeActualPeerDeadlineAndCancellation(t *testing.T) {
	for _, mode := range []string{"success", "blocked-read", "cancel", "death", "foreign-peer"} {
		t.Run(mode, func(t *testing.T) {
			req, reply := guestProbeFixture()
			nonce, err := freshVMSessionID()
			if err != nil {
				t.Fatal(err)
			}
			req.SessionID = nonce
			reply["sessionId"] = nonce
			fixtureMode := mode
			if mode == "cancel" {
				fixtureMode = "blocked-read"
			}
			peer, cleanup := vmGuestWindowsFixture(t, req, reply, fixtureMode)
			defer cleanup()
			expected := peer
			if mode == "foreign-peer" {
				expected, err = observeNativeProcessPeer(uint32(os.Getpid()))
				if err != nil {
					t.Fatal(err)
				}
				defer expected.close()
			}
			ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
			defer cancel()
			if mode == "cancel" {
				go func() { time.Sleep(50 * time.Millisecond); cancel() }()
			}
			began := time.Now()
			result, err := exchangeVMGuestPipe(ctx, expected, req)
			if mode == "success" {
				if err != nil {
					t.Fatal(err)
				}
				if result.DesktopQualified || result.EditorQualified {
					t.Fatal("transport became desktop proof")
				}
				return
			}
			if err == nil {
				t.Fatal("unavailable/foreign peer accepted")
			}
			if mode == "cancel" && time.Since(began) > 350*time.Millisecond {
				t.Fatalf("cancel waited for outer deadline: %v", time.Since(began))
			}
			if time.Since(began) > 2*time.Second {
				t.Fatal("pipe operation unbounded")
			}
			if mode == "foreign-peer" && !strings.Contains(err.Error(), "owned QEMU") {
				t.Fatalf("wrong refusal: %v", err)
			}
		})
	}
}
