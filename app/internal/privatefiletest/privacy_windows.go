//go:build windows

// Package privatefiletest provides platform-native confidentiality assertions.
package privatefiletest

import (
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

func AssertPrivate(t *testing.T, path string) {
	t.Helper()
	sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatal(err)
	}
	control, _, err := sd.Control()
	if err != nil || control&windows.SE_DACL_PROTECTED == 0 {
		t.Fatalf("private file inherits access: control=%x, error=%v", control, err)
	}
	user, err := windows.GetCurrentThreadEffectiveToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	groups, err := windows.GetCurrentThreadEffectiveToken().GetTokenGroups()
	if err != nil {
		t.Fatal(err)
	}
	privileged := false
	for _, group := range groups.AllGroups() {
		if group.Sid.IsWellKnown(windows.WinBuiltinAdministratorsSid) && group.Attributes&windows.SE_GROUP_ENABLED != 0 {
			privileged = true
		}
	}
	owner, _, err := sd.Owner()
	if err != nil || owner == nil {
		t.Fatalf("private file owner unavailable: %v", err)
	}
	allowed := func(sid *windows.SID) bool {
		return (!privileged && windows.EqualSid(sid, user.User.Sid)) || sid.IsWellKnown(windows.WinLocalSystemSid) || sid.IsWellKnown(windows.WinBuiltinAdministratorsSid)
	}
	if !allowed(owner) {
		t.Fatalf("private file owned by %s", owner.String())
	}
	acl, _, err := sd.DACL()
	if err != nil || acl == nil {
		t.Fatalf("private file has no restrictive DACL: %v", err)
	}
	ownerAccess := false
	for i := uint32(0); i < uint32(acl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, i, &ace); err != nil {
			t.Fatal(err)
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE || ace.Header.AceFlags&windows.INHERIT_ONLY_ACE != 0 {
			t.Fatalf("unexpected private file ACE type/flags: %d/%x", ace.Header.AceType, ace.Header.AceFlags)
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		if !allowed(sid) {
			t.Fatalf("private file grants %x to %s", ace.Mask, sid.String())
		}
		const readWrite = windows.FILE_GENERIC_READ | windows.FILE_GENERIC_WRITE
		if windows.EqualSid(sid, owner) && ace.Mask&readWrite == readWrite {
			ownerAccess = true
		}
	}
	if !ownerAccess {
		t.Fatal("private file owner lacks read/write access")
	}
}
