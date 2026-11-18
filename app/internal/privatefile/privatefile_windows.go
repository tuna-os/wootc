//go:build windows

package privatefile

import (
	"errors"
	"fmt"
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

func open(path string, exclusive bool) (*os.File, error) {
	token := windows.GetCurrentThreadEffectiveToken()
	user, err := token.GetTokenUser()
	if err != nil {
		return nil, pathError(path, err)
	}
	groups, err := token.GetTokenGroups()
	if err != nil {
		return nil, pathError(path, err)
	}
	isAdmin := false
	for _, group := range groups.AllGroups() {
		if group.Sid.IsWellKnown(windows.WinBuiltinAdministratorsSid) && group.Attributes&windows.SE_GROUP_ENABLED != 0 {
			isAdmin = true
			break
		}
	}
	// Elevated installer state must remain inaccessible to the same account's
	// unelevated token. Ordinary generators instead retain their own access.
	owner := user.User.Sid.String()
	grants := "(A;;FA;;;SY)(A;;FA;;;BA)"
	if isAdmin {
		owner = "BA"
	} else {
		grants += "(A;;FA;;;" + owner + ")"
	}
	sd, err := windows.SecurityDescriptorFromString("O:" + owner + "D:P" + grants)
	if err != nil {
		return nil, pathError(path, err)
	}
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, pathError(path, err)
	}
	sa := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: sd}
	disposition := uint32(windows.OPEN_ALWAYS)
	if exclusive {
		disposition = windows.CREATE_NEW
	}
	// Do not truncate on open or follow a reparse point. Pin the same object
	// against mutation/replacement while its descriptor is checked and written.
	h, err := windows.CreateFile(p, windows.GENERIC_WRITE|windows.READ_CONTROL|windows.FILE_READ_ATTRIBUTES,
		windows.FILE_SHARE_READ, &sa, disposition,
		windows.FILE_ATTRIBUTE_NORMAL|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, pathError(path, err)
	}
	f := os.NewFile(uintptr(h), path)
	if err := validate(h, user.User.Sid, isAdmin); err != nil {
		return nil, pathError(path, errors.Join(err, f.Close()))
	}
	return f, nil
}

func validate(h windows.Handle, user *windows.SID, isAdmin bool) error {
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(h, &info); err != nil {
		return err
	}
	if info.FileAttributes&(windows.FILE_ATTRIBUTE_REPARSE_POINT|windows.FILE_ATTRIBUTE_DIRECTORY) != 0 {
		return fmt.Errorf("private file is not a regular file")
	}
	sd, err := windows.GetSecurityInfo(h, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	trusted := func(sid *windows.SID) bool {
		return sid != nil && (sid.IsWellKnown(windows.WinLocalSystemSid) ||
			sid.IsWellKnown(windows.WinBuiltinAdministratorsSid) ||
			sid.String() == "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464" ||
			(!isAdmin && windows.EqualSid(sid, user)))
	}
	owner, _, err := sd.Owner()
	if err != nil {
		return err
	}
	if !trusted(owner) {
		return fmt.Errorf("private file has an untrusted owner")
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	if acl == nil {
		return fmt.Errorf("private file has an unrestricted DACL")
	}
	for i := uint32(0); i < uint32(acl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, i, &ace); err != nil {
			return err
		}
		if ace.Header.AceFlags&windows.INHERIT_ONLY_ACE != 0 {
			continue
		}
		switch ace.Header.AceType {
		case windows.ACCESS_DENIED_ACE_TYPE:
			continue
		case windows.ACCESS_ALLOWED_ACE_TYPE:
			if ace.Mask != 0 && !trusted((*windows.SID)(unsafe.Pointer(&ace.SidStart))) {
				return fmt.Errorf("private file grants access to an untrusted principal")
			}
		default:
			return fmt.Errorf("unsupported private file DACL entry type %d", ace.Header.AceType)
		}
	}
	return nil
}
