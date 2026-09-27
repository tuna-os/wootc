//go:build windows

package main

import (
	"fmt"
	"golang.org/x/sys/windows"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"unsafe"
)

// Creation must never have an interval with an inherited, permissive DACL.
const stateDirectorySDDL = "O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"

func trustedStateSID(sid *windows.SID) bool {
	if sid == nil {
		return false
	}
	return sid.IsWellKnown(windows.WinLocalSystemSid) || sid.IsWellKnown(windows.WinBuiltinAdministratorsSid) ||
		// Windows volume roots can belong to the Windows Modules Installer.
		sid.String() == "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"
}

// Allow ordinary users to read, never mutate. Denies do not cancel an allow:
// this conservative subset avoids emulating AccessCheck for every possible
// token. Unknown ACE forms fail closed.
func validateStateDescriptor(sd *windows.SECURITY_DESCRIPTOR, volumeRoot bool) error {
	owner, _, err := sd.Owner()
	if err != nil {
		return err
	}
	if !trustedStateSID(owner) {
		return fmt.Errorf("owner is not SYSTEM, Administrators or TrustedInstaller")
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	if acl == nil {
		return fmt.Errorf("missing DACL permits unrestricted access")
	}
	mask := uint32(windows.GENERIC_ALL | windows.GENERIC_WRITE | windows.WRITE_DAC | windows.WRITE_OWNER | windows.DELETE | 0x40 /* FILE_DELETE_CHILD */)
	if !volumeRoot {
		mask |= windows.FILE_WRITE_DATA | windows.FILE_APPEND_DATA | windows.FILE_WRITE_EA | windows.FILE_WRITE_ATTRIBUTES
	}
	for i := uint32(0); i < uint32(acl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, i, &ace); err != nil {
			return err
		}
		inheritOnly := ace.Header.AceFlags&windows.INHERIT_ONLY_ACE != 0
		if volumeRoot && inheritOnly {
			continue // the new state root gets a protected, explicit DACL
		}
		switch ace.Header.AceType {
		case windows.ACCESS_DENIED_ACE_TYPE:
			continue
		case windows.ACCESS_ALLOWED_ACE_TYPE:
			sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
			// CREATOR OWNER is mapped to the trusted creator on inheritance.
			if inheritOnly && sid.IsWellKnown(windows.WinCreatorOwnerSid) {
				continue
			}
			if uint32(ace.Mask)&mask != 0 && !trustedStateSID(sid) {
				return fmt.Errorf("DACL gives mutation rights to %s", sid.String())
			}
		default:
			return fmt.Errorf("unsupported DACL entry type %d", ace.Header.AceType)
		}
	}
	return nil
}

// Inspect the object itself, not a junction target. Parents are checked first,
// including the volume root's DELETE_CHILD rights: an ordinary user cannot
// substitute an already-validated component while its descendants are read.
func inspectStateObject(path string, volumeRoot bool) error {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	h, err := windows.CreateFile(p, windows.READ_CONTROL|windows.FILE_READ_ATTRIBUTES,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING,
		windows.FILE_FLAG_BACKUP_SEMANTICS|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(h)
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(h, &info); err != nil {
		return err
	}
	if info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return fmt.Errorf("reparse points are not allowed in installer state")
	}
	sd, err := windows.GetSecurityInfo(h, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return err
	}
	return validateStateDescriptor(sd, volumeRoot)
}

func ensureTrustedStateDirectory(root string) error {
	volume := filepath.VolumeName(root)
	if len(volume) != 2 || volume[1] != ':' || filepath.Clean(root) != volume+`\wootc` {
		return fmt.Errorf("invalid installer state location %q", root)
	}
	if err := inspectStateObject(volume+`\`, true); err != nil {
		return fmt.Errorf("unsafe state volume %s: %w", volume, err)
	}
	return prepareTrustedStateTree(root)
}

// Called only after the parent volume is trusted (or by isolated Windows tests).
func prepareTrustedStateTree(root string) error {
	sd, err := windows.SecurityDescriptorFromString(stateDirectorySDDL)
	if err != nil {
		return err
	}
	p, err := windows.UTF16PtrFromString(root)
	if err != nil {
		return err
	}
	sa := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: sd}
	if err := windows.CreateDirectory(p, &sa); err != nil && err != windows.ERROR_ALREADY_EXISTS {
		return err
	}
	if st, err := os.Lstat(root); err != nil {
		return err
	} else if !st.IsDir() {
		return fmt.Errorf("installer state %s is not a directory", root)
	}
	// Never repair an unsafe tree: that would bless planted SHA256SUMS/artifacts.
	err = filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := inspectStateObject(path, false); err != nil {
			return fmt.Errorf("unsafe installer state %s: %w", path, err)
		}
		return nil
	})
	if err != nil {
		return err
	}
	acl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(root, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil)
}

// Discovery and branding read state before installation. Audit existing trees
// on every fixed drive before either GUI or headless startup.
func initializeStateTrust() error {
	drives, err := windows.GetLogicalDrives()
	if err != nil {
		return err
	}
	for i := uint32(0); i < 26; i++ {
		if drives&(1<<i) == 0 {
			continue
		}
		volume := string(rune('A'+i)) + `:\`
		p, _ := windows.UTF16PtrFromString(volume)
		if windows.GetDriveType(p) != windows.DRIVE_FIXED {
			continue
		}
		root := volume + "wootc"
		if _, err := os.Lstat(root); os.IsNotExist(err) {
			continue
		} else if err != nil {
			return err
		}
		if err := ensureTrustedStateDirectory(root); err != nil {
			return err
		}
	}
	return ensureTrustedStateDirectory(wootcDir())
}

func reportStateTrustFailure(err error) {
	message := "The installer cannot safely use its existing files. " + err.Error() +
		". Ask an administrator to inspect this location and move untrusted files aside before trying again."
	fmt.Fprintln(os.Stderr, message)
	if !isHeadlessInvocation(os.Args) {
		text, _ := windows.UTF16PtrFromString(message)
		title, _ := windows.UTF16PtrFromString("wootc — unsafe installer state")
		_, _ = windows.MessageBox(0, text, title, windows.MB_OK|windows.MB_ICONERROR)
	}
}

// Commit the selected drive only after it has passed validation, so a rejected
// input cannot redirect later GUI state reads to an untrusted location.
func prepareInstallState(letter string) error {
	letter = strings.TrimSuffix(strings.ToUpper(strings.TrimSpace(letter)), ":")
	if letter == "" {
		letter = "C"
	}
	if len(letter) != 1 || letter[0] < 'A' || letter[0] > 'Z' {
		return fmt.Errorf("invalid storage drive %q", letter)
	}
	if err := ensureTrustedStateDirectory(letter + `:\wootc`); err != nil {
		return err
	}
	setStorageDrive(letter)
	return nil
}
