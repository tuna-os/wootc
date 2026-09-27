//go:build windows

package main

import (
	"fmt"
	"path/filepath"
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
	captured := &nativeOriginalUser{token: token, source: source, folders: map[string]string{}}
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
	if err != nil || actual != user.statistics {
		return fmt.Errorf("original user process token changed")
	}
	return nil
}
