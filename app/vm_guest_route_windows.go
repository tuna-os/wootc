//go:build windows

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"golang.org/x/sys/windows"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

func configureVMGuestChannel(cmd *exec.Cmd, state VMState, nonce string) (bool, error) {
	args, err := vmGuestRouteArgs(state, nonce)
	if err != nil {
		return false, err
	}
	if len(args) == 0 {
		return false, nil
	}
	cmd.Args = append(cmd.Args, args...)
	return true, nil
}

type nativeVMGuestTransport struct {
	mu         sync.Mutex
	peer       *nativeProcessPeer
	connection *os.File
	identity   vmGuestProbeRequest
	closed     bool
	seen       map[string]bool
}

func ownVMGuestObserver(cmd *exec.Cmd, enabled bool) (vmGuestTransport, error) {
	if !enabled {
		return nil, nil
	}
	if cmd.Process == nil {
		return nil, fmt.Errorf("observer requires launched owned QEMU")
	}
	peer, err := observeNativeProcessPeer(uint32(cmd.Process.Pid))
	if err != nil {
		return nil, err
	}
	if !strings.EqualFold(filepath.Clean(peer.imagePath), filepath.Clean(cmd.Path)) {
		peer.close()
		return nil, fmt.Errorf("observer process executable differs from owned QEMU")
	}
	return &nativeVMGuestTransport{peer: peer}, nil
}
func (t *nativeVMGuestTransport) retire() {
	if t.connection != nil {
		_ = t.connection.Close()
		t.connection = nil
	}
	t.closed = true
}
func (t *nativeVMGuestTransport) observe(ctx context.Context, req vmGuestProbeRequest) (result vmGuestProbeObservation, err error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err = ctx.Err(); err != nil {
		return result, err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if err = ctx.Err(); err != nil {
		return result, err
	}
	if t.peer == nil || t.closed {
		return result, fmt.Errorf("owned observer channel released")
	}
	if err = validateVMGuestRequest(req); err != nil {
		return result, err
	}
	identity := req
	identity.RequestID = ""
	if t.connection != nil && t.identity != identity {
		return result, fmt.Errorf("owned observer channel identity changed")
	}
	if t.seen == nil {
		t.seen = map[string]bool{}
	}
	if t.seen[req.RequestID] || len(t.seen) >= 128 {
		return result, fmt.Errorf("owned observer request replay or budget exhausted")
	}
	t.seen[req.RequestID] = true
	defer func() {
		if err != nil {
			t.retire()
		}
	}()
	if t.connection == nil {
		t.connection, err = openVMGuestPipe(ctx, t.peer, req.SessionID)
		if err != nil {
			return result, err
		}
		t.identity = identity
	}
	connection := t.connection
	deadline, _ := ctx.Deadline()
	if err = connection.SetDeadline(deadline); err != nil {
		return result, fmt.Errorf("observer channel requires bounded IO: %w", err)
	}
	finished := make(chan struct{})
	stop := context.AfterFunc(ctx, func() { _ = connection.Close(); close(finished) })
	defer func() {
		if !stop() {
			<-finished
		}
	}()
	handle := windows.Handle(connection.Fd())
	if err = verifyVMGuestPipeServer(handle, t.peer); err != nil {
		return result, err
	}
	raw, err := json.Marshal(req)
	if err != nil {
		return result, err
	}
	raw, err = vmGuestPipeFrame(connection, append(raw, '\n'))
	if err != nil {
		return result, err
	}
	if err = verifyVMGuestPipeServer(handle, t.peer); err != nil {
		return result, err
	}
	if err = ctx.Err(); err != nil {
		return result, err
	}
	return decodeVMGuestObservation(raw, req)
}
func (t *nativeVMGuestTransport) close() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.retire()
	if t.peer == nil {
		return nil
	}
	t.peer.close()
	t.peer = nil
	return nil
}
