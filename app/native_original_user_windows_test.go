//go:build windows

package main

import (
	"golang.org/x/sys/windows"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNativeOriginalUserRejectsMissingClosedOrAlternativeAdministrator(t *testing.T) {
	peer, err := observeNativeProcessPeer(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	defer peer.close()
	alternative := *peer
	alternative.userSID = "S-1-5-21-1-2-3-9999"
	for _, test := range []struct {
		name           string
		source, engine *nativeProcessPeer
	}{
		{"missing-source", nil, peer}, {"missing-engine", peer, nil}, {"alternative-admin", peer, &alternative},
	} {
		t.Run(test.name, func(t *testing.T) {
			if user, err := captureNativeOriginalUser(test.source, test.engine); err == nil {
				user.close()
				t.Fatal("unbound original user accepted")
			}
		})
	}
	closed := *peer
	closed.handle = 0
	if user, err := captureNativeOriginalUser(&closed, peer); err == nil {
		user.close()
		t.Fatal("closed source accepted")
	}
}

func TestNativeOriginalUserCannotReplaceObservedTokenWithPeerFields(t *testing.T) {
	peer, err := observeNativeProcessPeer(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	defer peer.close()
	// Both objects agree with each other, but disagree with the actual token.
	// An authorization object must derive identity from the retained token again.
	source, engine := *peer, *peer
	source.sessionID, engine.sessionID = 1, 1
	source.userSID, engine.userSID = "S-1-5-21-1-2-3-9999", "S-1-5-21-1-2-3-9999"
	engine.elevated = true
	if user, err := captureNativeOriginalUser(&source, &engine); err == nil {
		user.close()
		t.Fatal("wire-like peer claims replaced source token")
	}
}

func TestNativeOriginalUserActualTokenProfileAndBindingReadOnly(t *testing.T) {
	peer, err := observeNativeProcessPeer(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	defer peer.close()
	var token windows.Token
	if err := windows.OpenProcessToken(peer.handle, windows.TOKEN_QUERY|windows.TOKEN_IMPERSONATE|windows.TOKEN_DUPLICATE, &token); err != nil {
		t.Fatal(err)
	}
	defer token.Close()
	stats, err := observeNativeOriginalTokenStatistics(token)
	if err != nil {
		t.Fatal(err)
	}
	captured := &nativeOriginalUser{token: token, source: peer, statistics: stats}
	if err := captured.revalidateToken(); err != nil {
		t.Fatal(err)
	}
	t.Setenv("USERPROFILE", `Z:\untrusted-environment-profile`)
	profile, err := token.GetUserProfileDirectory()
	if err != nil {
		t.Fatal(err)
	}
	known, err := token.KnownFolderPath(windows.FOLDERID_Profile, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !filepath.IsAbs(profile) || !strings.EqualFold(filepath.Clean(profile), filepath.Clean(known)) || strings.Contains(profile, "untrusted-environment-profile") {
		t.Fatal("actual token profile binding refused")
	}
	captured.statistics.ModifiedID.LowPart++
	if captured.revalidateToken() == nil {
		t.Fatal("changed token security context accepted")
	}
}

func TestNativeOriginalUserActualNoninteractiveTokenRefuses(t *testing.T) {
	peer, err := observeNativeProcessPeer(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	defer peer.close()
	token, err := windows.OpenCurrentProcessToken()
	if err != nil {
		t.Fatal(err)
	}
	defer token.Close()
	groups, err := token.GetTokenGroups()
	if err != nil {
		t.Fatal(err)
	}
	interactive := false
	for _, g := range groups.AllGroups() {
		if g.Sid.IsWellKnown(windows.WinInteractiveSid) && g.Attributes&windows.SE_GROUP_ENABLED != 0 && g.Attributes&windows.SE_GROUP_USE_FOR_DENY_ONLY == 0 {
			interactive = true
		}
	}
	if interactive && peer.sessionID != 0 {
		t.Fatal("hosted refusal control requires an actual noninteractive token; inconclusive")
	}
	if user, err := captureNativeOriginalUser(peer, peer); err == nil {
		user.close()
		t.Fatal("noninteractive token accepted as original user")
	}
}
