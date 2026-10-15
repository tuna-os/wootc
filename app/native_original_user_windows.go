//go:build windows

package main

import (
	"fmt"
	"path/filepath"
	"runtime"
	"unsafe"

	"golang.org/x/sys/windows"
)

// nativeOriginalUser is captured from a retained authenticated shell process.
// Neither this object nor its token can be supplied through an RPC DTO. Capture
// alone never authorizes installation or upgrades an assessment connection.
type nativeOriginalUser struct {
	token      windows.Token
	source     *nativeProcessPeer
	sid        string
	session    uint32
	profile    string
	folders    map[string]string
	statistics nativeOriginalTokenStatistics
	// viaPipe marks a token retained from pipe impersonation. It is a
	// distinct token object, so revalidation compares its logon session with
	// the live source process rather than the process token's statistics.
	viaPipe bool
}

func captureNativeOriginalUser(source, engine *nativeProcessPeer) (*nativeOriginalUser, error) {
	if source == nil || engine == nil || source.checkAlive() != nil || engine.checkAlive() != nil {
		return nil, fmt.Errorf("original user process unavailable")
	}
	if source.sessionID == 0 || source.sessionID != engine.sessionID || source.userSID != engine.userSID || !engine.elevated {
		return nil, fmt.Errorf("original user context refused")
	}
	var token windows.Token
	if err := windows.OpenProcessToken(source.handle, windows.TOKEN_QUERY|windows.TOKEN_IMPERSONATE|windows.TOKEN_DUPLICATE, &token); err != nil {
		return nil, fmt.Errorf("original user token unavailable")
	}
	return completeNativeOriginalUser(token, source, engine, false)
}

// captureNativeOriginalUserFromPipe is the original-user bridge for
// alternative-administrator UAC: a standard user supplies another
// administrator's credentials, so the elevated engine runs as a different
// SID. The person whose files migrate is the authenticated pipe client, so
// identity comes from that client's own token through
// ImpersonateNamedPipeClient (docs/winui-shell.md, "Correct elevation and
// transport", step 6). The engine's own HKCU, USERPROFILE and profile are
// never consulted, and any impersonation failure refuses the capture.
// The caller must already have read client data and run
// verifyNativePipeClient on this exact pipe.
func captureNativeOriginalUserFromPipe(pipe windows.Handle, source, engine *nativeProcessPeer) (*nativeOriginalUser, error) {
	if source == nil || engine == nil || source.checkAlive() != nil || engine.checkAlive() != nil {
		return nil, fmt.Errorf("original user process unavailable")
	}
	if source.sessionID == 0 || source.sessionID != engine.sessionID || !engine.elevated {
		return nil, fmt.Errorf("original user context refused")
	}
	var pid uint32
	if err := windows.GetNamedPipeClientProcessId(pipe, &pid); err != nil || pid != source.pid {
		return nil, fmt.Errorf("original user pipe client is not the retained source")
	}
	token, err := openNativePipeClientToken(pipe)
	if err != nil {
		return nil, err
	}
	var level, returned uint32
	if err := windows.GetTokenInformation(token, windows.TokenImpersonationLevel, (*byte)(unsafe.Pointer(&level)), 4, &returned); err != nil || returned != 4 || level < 2 /* SecurityImpersonation */ {
		token.Close()
		return nil, fmt.Errorf("original user pipe client refused impersonation")
	}
	return completeNativeOriginalUser(token, source, engine, true)
}

// openNativePipeClientToken retains the client's impersonation token. The
// locked thread returns to the pool only after RevertToSelf succeeds;
// otherwise its goroutine exits locked and Go retires that OS thread.
func openNativePipeClientToken(pipe windows.Handle) (windows.Token, error) {
	type opened struct {
		token windows.Token
		err   error
	}
	result := make(chan opened, 1)
	go func() {
		runtime.LockOSThread()
		var value opened
		impersonated := false
		defer func() {
			canUnlock := true
			if impersonated {
				if err := windows.RevertToSelf(); err != nil {
					if value.token != 0 {
						value.token.Close()
					}
					value = opened{err: fmt.Errorf("original user impersonation could not be reverted")}
					canUnlock = false
				}
			}
			if canUnlock {
				runtime.UnlockOSThread()
			}
			result <- value
		}()
		if ok, _, _ := nativeImpersonatePipeClient.Call(uintptr(pipe)); ok == 0 {
			value.err = fmt.Errorf("original user pipe impersonation refused")
			return
		}
		impersonated = true
		// OpenAsSelf: the engine opens the thread token with its own access
		// check; the impersonated client never needs rights on its own token.
		if err := windows.OpenThreadToken(windows.CurrentThread(), windows.TOKEN_QUERY|windows.TOKEN_IMPERSONATE|windows.TOKEN_DUPLICATE, true, &value.token); err != nil {
			value = opened{err: fmt.Errorf("original user pipe token unavailable")}
		}
	}()
	value := <-result
	return value.token, value.err
}

func completeNativeOriginalUser(token windows.Token, source, engine *nativeProcessPeer, viaPipe bool) (*nativeOriginalUser, error) {
	captured := &nativeOriginalUser{token: token, source: source, folders: map[string]string{}, viaPipe: viaPipe}
	success := false
	defer func() {
		if !success {
			captured.close()
		}
	}()
	statistics, err := observeNativeOriginalTokenStatistics(token)
	if err != nil {
		return nil, err
	}
	captured.statistics = statistics
	user, err := token.GetTokenUser()
	if err != nil || user.User.Sid.String() != source.userSID {
		return nil, fmt.Errorf("original user token identity changed")
	}
	var session, returned uint32
	if err := windows.GetTokenInformation(token, windows.TokenSessionId, (*byte)(unsafe.Pointer(&session)), 4, &returned); err != nil || returned != 4 || session != source.sessionID {
		return nil, fmt.Errorf("original user token session changed")
	}
	groups, err := token.GetTokenGroups()
	if err != nil {
		return nil, fmt.Errorf("original user logon unavailable")
	}
	interactive := false
	for _, group := range groups.AllGroups() {
		if group.Sid.IsWellKnown(windows.WinInteractiveSid) && group.Attributes&windows.SE_GROUP_ENABLED != 0 && group.Attributes&windows.SE_GROUP_USE_FOR_DENY_ONLY == 0 {
			interactive = true
		}
	}
	if !interactive {
		return nil, fmt.Errorf("original user interactive logon required")
	}
	profile, err := token.GetUserProfileDirectory()
	if err != nil || !filepath.IsAbs(profile) {
		return nil, fmt.Errorf("original user profile unavailable")
	}
	// Flags zero never requests creation. The source token selects redirected or
	// localized folders; elevated HKCU and inherited USERPROFILE are unused.
	for name, id := range map[string]*windows.KNOWNFOLDERID{
		"Desktop": windows.FOLDERID_Desktop, "Documents": windows.FOLDERID_Documents,
		"Downloads": windows.FOLDERID_Downloads, "Music": windows.FOLDERID_Music,
		"Pictures": windows.FOLDERID_Pictures, "Videos": windows.FOLDERID_Videos,
	} {
		path, err := token.KnownFolderPath(id, 0)
		if err != nil || !filepath.IsAbs(path) {
			return nil, fmt.Errorf("original user known folder unavailable")
		}
		captured.folders[name] = filepath.Clean(path)
	}
	if source.checkAlive() != nil || engine.checkAlive() != nil {
		return nil, fmt.Errorf("original user process exited during capture")
	}
	if err := captured.revalidateToken(); err != nil {
		return nil, err
	}
	captured.sid, captured.session, captured.profile = source.userSID, session, filepath.Clean(profile)
	success = true
	return captured, nil
}

func (user *nativeOriginalUser) close() {
	if user.token != 0 {
		user.token.Close()
		user.token = 0
	}
	user.sid, user.profile = "", ""
	user.session = 0
	clear(user.folders)
}

// TOKEN_STATISTICS is measured eagerly, so a changed token object or a modified
// security context cannot be hidden behind unchanged process SID/session fields.
// https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-token_statistics
type nativeOriginalTokenStatistics struct {
	TokenID, AuthenticationID                                    windows.LUID
	ExpirationTime                                               int64
	TokenType, ImpersonationLevel                                uint32
	DynamicCharged, DynamicAvailable, GroupCount, PrivilegeCount uint32
	ModifiedID                                                   windows.LUID
}

func observeNativeOriginalTokenStatistics(token windows.Token) (nativeOriginalTokenStatistics, error) {
	var value nativeOriginalTokenStatistics
	var returned uint32
	size := uint32(unsafe.Sizeof(value))
	if err := windows.GetTokenInformation(token, windows.TokenStatistics, (*byte)(unsafe.Pointer(&value)), size, &returned); err != nil || returned != size {
		return value, fmt.Errorf("original user token statistics unavailable")
	}
	return value, nil
}

func (user *nativeOriginalUser) revalidateToken() error {
	if user.token == 0 || user.source == nil || user.source.checkAlive() != nil {
		return fmt.Errorf("original user capture unavailable")
	}
	retained, err := observeNativeOriginalTokenStatistics(user.token)
	if err != nil || retained != user.statistics {
		return fmt.Errorf("original user token security context changed")
	}
	var current windows.Token
	if err := windows.OpenProcessToken(user.source.handle, windows.TOKEN_QUERY, &current); err != nil {
		return fmt.Errorf("original user current token unavailable")
	}
	defer current.Close()
	actual, err := observeNativeOriginalTokenStatistics(current)
	if err != nil {
		return fmt.Errorf("original user process token changed")
	}
	if user.viaPipe {
		owner, err := current.GetTokenUser()
		if err != nil || owner.User.Sid.String() != user.source.userSID || actual.AuthenticationID != user.statistics.AuthenticationID {
			return fmt.Errorf("original user process token changed")
		}
		return nil
	}
	if actual != user.statistics {
		return fmt.Errorf("original user process token changed")
	}
	return nil
}
