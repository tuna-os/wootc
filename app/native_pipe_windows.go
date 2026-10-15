//go:build windows

package main

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

var nativeImpersonatePipeClient = windows.NewLazySystemDLL("advapi32.dll").NewProc("ImpersonateNamedPipeClient")

// verifyNativePipeClient observes kernel pipe/process identities. The caller
// must read the bounded hello first, then verify its protected package/build
// binding before initializing state or exposing RPC. A hello SID is never used.
func verifyNativePipeClient(pipe windows.Handle, expected *nativeProcessPeer) error {
	if expected == nil {
		return fmt.Errorf("native source process observation is required")
	}
	if err := expected.checkAlive(); err != nil {
		return err
	}
	var pid uint32
	if err := windows.GetNamedPipeClientProcessId(pipe, &pid); err != nil {
		return fmt.Errorf("native pipe client PID: %w", err)
	}
	if pid != expected.pid {
		return fmt.Errorf("native pipe client is not the retained source process")
	}
	actual, err := observeNativeProcessPeer(pid)
	if err != nil {
		return err
	}
	defer actual.close()
	if actual.userSID != expected.userSID || actual.sessionID != expected.sessionID ||
		!strings.EqualFold(actual.imagePath, expected.imagePath) {
		return fmt.Errorf("native source process identity changed")
	}
	if err := verifyNativePipeToken(pipe, expected.userSID, expected.sessionID); err != nil {
		return err
	}
	return expected.checkAlive()
}

// Inspect the effective token associated with the last pipe message, rather
// than assuming that the process token represents an impersonating client.
// An isolated locked thread cannot return to the engine pool if RevertToSelf
// fails: exiting its goroutine while still locked retires that OS thread.
func verifyNativePipeToken(pipe windows.Handle, userSID string, sessionID uint32) error {
	result := make(chan error, 1)
	go func() {
		runtime.LockOSThread()
		var failure error
		impersonated := false
		defer func() {
			canUnlock := true
			if impersonated {
				if err := windows.RevertToSelf(); err != nil {
					failure = fmt.Errorf("revert native pipe token: %w", err)
					canUnlock = false
				}
			}
			if canUnlock {
				runtime.UnlockOSThread()
			}
			result <- failure
		}()
		ok, _, callError := nativeImpersonatePipeClient.Call(uintptr(pipe))
		if ok == 0 {
			failure = fmt.Errorf("observe native pipe effective token: %v", callError)
			return
		}
		impersonated = true
		var token windows.Token
		if err := windows.OpenThreadToken(windows.CurrentThread(), windows.TOKEN_QUERY, true, &token); err != nil {
			failure = fmt.Errorf("open native pipe effective token: %w", err)
			return
		}
		defer token.Close()
		user, err := token.GetTokenUser()
		if err != nil {
			failure = fmt.Errorf("native pipe effective user: %w", err)
			return
		}
		var actualSession, size uint32
		if err := windows.GetTokenInformation(token, windows.TokenSessionId, (*byte)(unsafe.Pointer(&actualSession)), 4, &size); err != nil {
			failure = fmt.Errorf("native pipe effective session: %w", err)
			return
		}
		if size != 4 || user.User.Sid.String() != userSID || actualSession != sessionID {
			failure = fmt.Errorf("native pipe effective identity differs from the source process")
		}
	}()
	return <-result
}

// createNativePipe reserves one local-only session endpoint before launching the
// client. The source user's grant excludes FILE_CREATE_PIPE_INSTANCE: knowing
// the endpoint name cannot authorize a competing server instance.
func createNativePipe(name string, source *nativeProcessPeer) (windows.Handle, error) {
	if source == nil {
		return windows.InvalidHandle, fmt.Errorf("native source process observation is required")
	}
	if err := source.checkAlive(); err != nil {
		return windows.InvalidHandle, err
	}
	const prefix = `\\.\pipe\wootc-preview-`
	session := strings.TrimPrefix(name, prefix)
	if !strings.HasPrefix(name, prefix) || len(session) != 32 {
		return windows.InvalidHandle, fmt.Errorf("invalid native session pipe name")
	}
	for _, character := range session {
		if !((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')) {
			return windows.InvalidHandle, fmt.Errorf("invalid native session pipe name")
		}
	}
	sd, err := windows.SecurityDescriptorFromString("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x0012019b;;;" + source.userSID + ")")
	if err != nil {
		return windows.InvalidHandle, fmt.Errorf("native pipe security descriptor: %w", err)
	}
	attributes := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: sd}
	path, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return windows.InvalidHandle, err
	}
	return windows.CreateNamedPipe(path, windows.PIPE_ACCESS_DUPLEX|windows.FILE_FLAG_FIRST_PIPE_INSTANCE|windows.FILE_FLAG_OVERLAPPED,
		windows.PIPE_TYPE_BYTE|windows.PIPE_READMODE_BYTE|windows.PIPE_WAIT|windows.PIPE_REJECT_REMOTE_CLIENTS, 1, 16384, 16384, 0, &attributes)
}

// connectNativePipe bounds the kernel connection wait and drains cancellation
// before releasing OVERLAPPED/event memory. Closing a connection later cancels
// its own IO; no broad process or pipe-name cleanup is used.
func connectNativePipe(ctx context.Context, pipe windows.Handle) error {
	event, err := windows.CreateEvent(nil, 1, 0, nil)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(event)
	overlapped := windows.Overlapped{HEvent: event}
	err = windows.ConnectNamedPipe(pipe, &overlapped)
	if err == nil || errors.Is(err, windows.ERROR_PIPE_CONNECTED) {
		return nil
	}
	if !errors.Is(err, windows.ERROR_IO_PENDING) {
		return err
	}
	var transferred uint32
	for {
		if err := ctx.Err(); err != nil {
			_ = windows.CancelIoEx(pipe, &overlapped)
			_ = windows.GetOverlappedResult(pipe, &overlapped, &transferred, true)
			return err
		}
		state, err := windows.WaitForSingleObject(event, 50)
		if err != nil {
			_ = windows.CancelIoEx(pipe, &overlapped)
			_ = windows.GetOverlappedResult(pipe, &overlapped, &transferred, true)
			return err
		}
		if state == windows.WAIT_OBJECT_0 {
			return windows.GetOverlappedResult(pipe, &overlapped, &transferred, false)
		}
	}
}
