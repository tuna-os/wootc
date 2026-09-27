//go:build windows

package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

func nativeTestPipe(t *testing.T) (windows.Handle, string, *nativeProcessPeer) {
	t.Helper()
	peer, err := observeNativeProcessPeer(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(peer.close)
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		t.Fatal(err)
	}
	name := `\\.\pipe\wootc-preview-` + hex.EncodeToString(random[:])
	pipe, err := createNativePipe(name, peer)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { windows.CloseHandle(pipe) })
	return pipe, name, peer
}

func TestNativePipeActualConnectionIdentity(t *testing.T) {
	pipe, name, peer := nativeTestPipe(t)
	path, err := windows.UTF16PtrFromString(name)
	if err != nil {
		t.Fatal(err)
	}
	// Match the narrow source-user ACE, without the generic-write instance bit.
	client, err := windows.CreateFile(path, 0x0012019b, 0, nil, windows.OPEN_EXISTING, windows.SECURITY_SQOS_PRESENT|windows.SECURITY_IMPERSONATION, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(client)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := connectNativePipe(ctx, pipe); err != nil {
		t.Fatal(err)
	}
	var written uint32
	if err := windows.WriteFile(client, []byte("H"), &written, nil); err != nil || written != 1 {
		t.Fatalf("client message: %v, %d", err, written)
	}
	event, err := windows.CreateEvent(nil, 1, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(event)
	overlapped := windows.Overlapped{HEvent: event}
	var read uint32
	buffer := make([]byte, 1)
	err = windows.ReadFile(pipe, buffer, &read, &overlapped)
	if errors.Is(err, windows.ERROR_IO_PENDING) {
		state, waitErr := windows.WaitForSingleObject(event, 5000)
		if waitErr != nil || state != windows.WAIT_OBJECT_0 {
			_ = windows.CancelIoEx(pipe, &overlapped)
			_ = windows.GetOverlappedResult(pipe, &overlapped, &read, true)
			t.Fatalf("bounded message wait: %v, %d", waitErr, state)
		}
		err = windows.GetOverlappedResult(pipe, &overlapped, &read, false)
	}
	if err != nil || read != 1 || buffer[0] != 'H' {
		t.Fatalf("server message: %v, %d", err, read)
	}
	if err := verifyNativePipeClient(pipe, peer); err != nil {
		t.Fatal(err)
	}
	if err := verifyNativePipeToken(pipe, "S-1-5-7", peer.sessionID); err == nil {
		t.Fatal("wrong actual effective user accepted")
	}
	if err := verifyNativePipeToken(pipe, peer.userSID, peer.sessionID+1); err == nil {
		t.Fatal("wrong actual effective session accepted")
	}
	wrongPID := *peer
	wrongPID.pid++
	if err := verifyNativePipeClient(pipe, &wrongPID); err == nil {
		t.Fatal("different client process accepted")
	}
	if err := verifyNativePipeClient(pipe, nil); err == nil {
		t.Fatal("absent process observation accepted")
	}
	// Each failed impersonation check must restore this thread before the next.
	if err := verifyNativePipeClient(pipe, peer); err != nil {
		t.Fatal(err)
	}
	var duplicate windows.Handle
	if err := windows.DuplicateHandle(windows.CurrentProcess(), pipe, windows.CurrentProcess(), &duplicate, 0, false, windows.DUPLICATE_SAME_ACCESS); err != nil {
		t.Fatal(err)
	}
	connection := os.NewFile(uintptr(duplicate), name)
	if connection == nil {
		windows.CloseHandle(duplicate)
		t.Fatal("pipe connection unavailable")
	}
	defer connection.Close()
	if err := connection.SetReadDeadline(time.Now().Add(50 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	if _, err := connection.Read(make([]byte, 1)); !os.IsTimeout(err) {
		t.Fatalf("native pipe read deadline was not observed: %v", err)
	}
	if err := connection.SetReadDeadline(time.Time{}); err != nil {
		t.Fatal(err)
	}
	readFinished := make(chan error, 1)
	go func() { _, err := connection.Read(make([]byte, 1)); readFinished <- err }()
	time.Sleep(50 * time.Millisecond)
	if err := connection.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-readFinished:
		if err == nil {
			t.Fatal("closed connection read succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("disconnect did not release pending native pipe read")
	}
}

func TestNativePipeFirstInstanceAndCancellation(t *testing.T) {
	pipe, name, peer := nativeTestPipe(t)
	duplicate, err := createNativePipe(name, peer)
	if err == nil {
		windows.CloseHandle(duplicate)
		t.Fatal("competing server instance accepted")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	started := time.Now()
	if err := connectNativePipe(ctx, pipe); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("missing client did not cancel: %v", err)
	}
	if time.Since(started) > 2*time.Second {
		t.Fatal("connection cancellation exceeded bounded wait")
	}
	if err := peer.checkAlive(); err != nil {
		t.Fatal("pipe cancellation affected source process")
	}
}
