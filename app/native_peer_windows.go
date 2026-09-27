//go:build windows

package main

import (
	"fmt"
	"unsafe"

	"golang.org/x/sys/windows"
)

// nativeProcessPeer retains the observed process handle, preventing a recycled
// PID from becoming the authenticated peer. Values come from Windows tokens
// and process APIs; wire claims must never populate this object.
type nativeProcessPeer struct {
	handle    windows.Handle
	pid       uint32
	userSID   string
	sessionID uint32
	imagePath string
	elevated  bool
}

func observeNativeProcessPeer(pid uint32) (*nativeProcessPeer, error) {
	if pid == 0 {
		return nil, fmt.Errorf("native peer PID is required")
	}
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION|windows.SYNCHRONIZE, false, pid)
	if err != nil {
		return nil, fmt.Errorf("open native peer: %w", err)
	}
	peer := &nativeProcessPeer{handle: handle, pid: pid}
	succeeded := false
	defer func() {
		if !succeeded {
			peer.close()
		}
	}()
	if err = peer.checkAlive(); err != nil {
		return nil, err
	}
	var token windows.Token
	if err = windows.OpenProcessToken(handle, windows.TOKEN_QUERY, &token); err != nil {
		return nil, fmt.Errorf("native peer token: %w", err)
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return nil, fmt.Errorf("native peer user: %w", err)
	}
	peer.userSID = user.User.Sid.String()
	if err = windows.ProcessIdToSessionId(pid, &peer.sessionID); err != nil {
		return nil, fmt.Errorf("native peer session: %w", err)
	}
	var tokenSession, returned uint32
	if err = windows.GetTokenInformation(token, windows.TokenSessionId, (*byte)(unsafe.Pointer(&tokenSession)), 4, &returned); err != nil {
		return nil, fmt.Errorf("native token session: %w", err)
	}
	if returned != 4 || tokenSession != peer.sessionID {
		return nil, fmt.Errorf("native process and token sessions disagree")
	}
	var elevated uint32
	if err = windows.GetTokenInformation(token, windows.TokenElevation, (*byte)(unsafe.Pointer(&elevated)), 4, &returned); err != nil {
		return nil, fmt.Errorf("native token elevation: %w", err)
	}
	if returned != 4 {
		return nil, fmt.Errorf("native token elevation has invalid size")
	}
	peer.elevated = elevated != 0
	path := make([]uint16, 32768)
	size := uint32(len(path))
	if err = windows.QueryFullProcessImageName(handle, 0, &path[0], &size); err != nil {
		return nil, fmt.Errorf("native peer image: %w", err)
	}
	peer.imagePath = windows.UTF16ToString(path[:size])
	if peer.userSID == "" || peer.imagePath == "" {
		return nil, fmt.Errorf("native peer identity is incomplete")
	}
	if err = peer.checkAlive(); err != nil {
		return nil, err
	}
	succeeded = true
	return peer, nil
}

func (peer *nativeProcessPeer) checkAlive() error {
	if peer.handle == 0 {
		return fmt.Errorf("native peer handle is closed")
	}
	state, err := windows.WaitForSingleObject(peer.handle, 0)
	if err != nil {
		return fmt.Errorf("native peer liveness: %w", err)
	}
	if state != uint32(windows.WAIT_TIMEOUT) {
		return fmt.Errorf("native peer process has exited")
	}
	return nil
}

func (peer *nativeProcessPeer) close() {
	if peer.handle != 0 {
		windows.CloseHandle(peer.handle)
		peer.handle = 0
	}
}
