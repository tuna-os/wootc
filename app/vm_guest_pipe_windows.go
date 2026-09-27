//go:build windows

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"golang.org/x/sys/windows"
)

// The managed route enables a persistent instance only after authenticated
// installation hashes are retained. This one-shot helper remains a component
// control boundary; successful managed requests keep their channel open.
// expected must be retained from the engine-owned QEMU process at launch;
// neither a guest nor a public RPC can supply it.
func vmGuestPipeName(sessionID string) (string, error) {
	if !validDisplayDirective(sessionID) {
		return "", fmt.Errorf("invalid owned guest session")
	}
	return `\\.\pipe\wootc.observation.` + sessionID, nil
}
func verifyVMGuestPipeServer(pipe windows.Handle, expected *nativeProcessPeer) error {
	if expected == nil {
		return fmt.Errorf("owned QEMU process observation required")
	}
	if err := expected.checkAlive(); err != nil {
		return err
	}
	var pid uint32
	if err := windows.GetNamedPipeServerProcessId(pipe, &pid); err != nil {
		return err
	}
	if pid != expected.pid {
		return fmt.Errorf("guest pipe is not served by owned QEMU")
	}
	actual, err := observeNativeProcessPeer(pid)
	if err != nil {
		return err
	}
	defer actual.close()
	if actual.userSID != expected.userSID || actual.sessionID != expected.sessionID || !strings.EqualFold(actual.imagePath, expected.imagePath) {
		return fmt.Errorf("owned QEMU pipe process identity changed")
	}
	return expected.checkAlive()
}
func exchangeVMGuestPipe(ctx context.Context, expected *nativeProcessPeer, request vmGuestProbeRequest) (vmGuestProbeObservation, error) {
	var result vmGuestProbeObservation
	if err := validateVMGuestRequest(request); err != nil {
		return result, err
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return result, err
	}
	connection, err := openVMGuestPipe(ctx, expected, request.SessionID)
	if err != nil {
		return result, err
	}
	defer connection.Close()
	stopCancellation := context.AfterFunc(ctx, func() { _ = connection.Close() })
	defer stopCancellation()
	deadline, _ := ctx.Deadline()
	if err = connection.SetDeadline(deadline); err != nil {
		return result, fmt.Errorf("guest pipe requires bounded IO: %w", err)
	}
	if err = verifyVMGuestPipeServer(windows.Handle(connection.Fd()), expected); err != nil {
		return result, err
	}
	payload, err := json.Marshal(request)
	if err != nil {
		return result, err
	}
	payload = append(payload, '\n')
	raw, err := vmGuestPipeFrame(connection, payload)
	if err != nil {
		return result, err
	}

	if err = verifyVMGuestPipeServer(windows.Handle(connection.Fd()), expected); err != nil {
		return result, err
	}
	if err = ctx.Err(); err != nil {
		return result, err
	}
	return decodeVMGuestObservation(raw, request)
}

func openVMGuestPipe(ctx context.Context, expected *nativeProcessPeer, sessionID string) (*os.File, error) {
	if expected == nil {
		return nil, fmt.Errorf("owned QEMU process observation required")
	}
	if err := expected.checkAlive(); err != nil {
		return nil, err
	}
	name, err := vmGuestPipeName(sessionID)
	if err != nil {
		return nil, err
	}
	path, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return nil, err
	}
	var pipe windows.Handle
	for {
		if err := expected.checkAlive(); err != nil {
			return nil, err
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		pipe, err = windows.CreateFile(path, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OVERLAPPED, 0)
		if err == nil {
			break
		}
		if !errors.Is(err, windows.ERROR_FILE_NOT_FOUND) && !errors.Is(err, windows.ERROR_PIPE_BUSY) {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
	connection := os.NewFile(uintptr(pipe), name)
	if connection == nil {
		windows.CloseHandle(pipe)
		return nil, fmt.Errorf("owned guest pipe unavailable")
	}
	return connection, nil
}

// Internal bounded IO primitive; production callers supply only typed probes.
func vmGuestPipeFrame(connection *os.File, payload []byte) ([]byte, error) {
	if len(payload) == 0 || len(payload) > 256<<10 || payload[len(payload)-1] != '\n' {
		return nil, fmt.Errorf("guest request frame outside bound")
	}
	if n, e := connection.Write(payload); e != nil || n != len(payload) {
		if e == nil {
			e = io.ErrShortWrite
		}
		return nil, fmt.Errorf("write guest request: %w", e)
	}
	reader := bufio.NewReader(io.LimitReader(connection, (256<<10)+1))
	raw, err := reader.ReadBytes('\n')
	if err != nil {
		return nil, fmt.Errorf("read guest reply: %w", err)
	}
	if len(raw) > 256<<10 {
		return nil, fmt.Errorf("guest reply exceeds bound")
	}
	if reader.Buffered() != 0 {
		return nil, fmt.Errorf("unsolicited guest reply bytes")
	}
	return raw, nil
}
