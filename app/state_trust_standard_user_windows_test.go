//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Run only with the controlled disposable account and fresh NTFS volume.
func TestNativeStateStandardUserAndAlternateVolume(t *testing.T) {
	user, password, sid := os.Getenv("WOOTC_ACL_USER"), os.Getenv("WOOTC_ACL_PASSWORD"), os.Getenv("WOOTC_ACL_SID")
	fixture, alternate := os.Getenv("WOOTC_ACL_FIXTURE"), os.Getenv("WOOTC_ACL_ALTERNATE")
	if user == "" || password == "" || sid == "" || fixture == "" || alternate == "" {
		t.Skip("requires controlled native account and NTFS volume fixture")
	}
	if filepath.Base(fixture) == "wootc" || len(alternate) != 3 || alternate[1:] != `:\` {
		t.Fatal("invalid owned fixture inputs")
	}
	dll := windows.NewLazySystemDLL("advapi32.dll")
	u, _ := windows.UTF16PtrFromString(user)
	d, _ := windows.UTF16PtrFromString(".")
	p, _ := windows.UTF16PtrFromString(password)
	var token windows.Token
	ok, _, err := dll.NewProc("LogonUserW").Call(uintptr(unsafe.Pointer(u)), uintptr(unsafe.Pointer(d)), uintptr(unsafe.Pointer(p)), 2, 0, uintptr(unsafe.Pointer(&token)))
	if ok == 0 {
		t.Fatalf("native fixture logon refused: %v", err)
	}
	defer token.Close()
	identity, err := token.GetTokenUser()
	if err != nil || identity.User.Sid.String() != sid || token.IsElevated() {
		t.Fatal("token is not the expected unelevated user")
	}
	asUser := func(fn func() error) error {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		ok, _, err := dll.NewProc("ImpersonateLoggedOnUser").Call(uintptr(token))
		if ok == 0 {
			return fmt.Errorf("impersonate native logon token: %w", err)
		}
		defer func() {
			if ok, _, err := dll.NewProc("RevertToSelf").Call(); ok == 0 {
				panic(err)
			}
		}()
		var threadToken windows.Token
		if err := windows.OpenThreadToken(windows.CurrentThread(), windows.TOKEN_QUERY, true, &threadToken); err != nil {
			return fmt.Errorf("read actual thread token: %w", err)
		}
		defer threadToken.Close()
		actual, err := threadToken.GetTokenUser()
		if err != nil {
			return err
		}
		if actual.User.Sid.String() != sid {
			return fmt.Errorf("native filesystem operation has wrong thread identity")
		}
		return fn()
	}
	groups, err := token.GetTokenGroups()
	if err != nil {
		t.Fatalf("read actual logon token groups: %v", err)
	}
	users := false
	for _, group := range groups.AllGroups() {
		if group.Sid.IsWellKnown(windows.WinBuiltinAdministratorsSid) {
			t.Fatal("fixture token contains Administrators")
		}
		if group.Sid.IsWellKnown(windows.WinBuiltinUsersSid) && group.Attributes&windows.SE_GROUP_ENABLED != 0 {
			users = true
		}
	}
	if !users {
		t.Fatal("fixture token lacks enabled Users group")
	}
	for _, tc := range []struct {
		name, root, writable string
		prepare              func(string) error
	}{
		{"system-volume", filepath.Join(fixture, "wootc"), fixture, prepareTrustedStateTree},
		{"alternate-NTFS", alternate + "wootc", alternate, ensureTrustedStateDirectory},
	} {
		t.Run(tc.name, func(t *testing.T) {
			control := filepath.Join(tc.writable, "public-standard-user-control.txt")
			if err := asUser(func() error { return os.WriteFile(control, []byte("public control"), 0600) }); err != nil {
				t.Fatalf("positive standard-user write: %v", err)
			}
			defer os.Remove(control)
			planted := filepath.Join(tc.root, "install", "SHA256SUMS")
			if err := asUser(func() error {
				if err := os.MkdirAll(filepath.Dir(planted), 0700); err != nil {
					return err
				}
				return os.WriteFile(planted, []byte("public planted manifest"), 0600)
			}); err != nil {
				t.Fatalf("actual standard-user precreation: %v", err)
			}
			descriptor, err := windows.GetNamedSecurityInfo(tc.root, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
			if err != nil {
				t.Fatal(err)
			}
			before := descriptor.String()
			if err := tc.prepare(tc.root); err == nil {
				t.Fatal("accepted standard-user planted state")
			}
			descriptor, err = windows.GetNamedSecurityInfo(tc.root, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
			if err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(planted)
			if err != nil || string(data) != "public planted manifest" || descriptor.String() != before {
				t.Fatal("refusal changed planted bytes or descriptor")
			}
			if err := os.RemoveAll(tc.root); err != nil {
				t.Fatal(err)
			}
			if err := tc.prepare(tc.root); err != nil {
				t.Fatalf("trusted atomic creation: %v", err)
			}
			install := filepath.Join(tc.root, "install")
			if err := os.Mkdir(install, 0700); err != nil {
				t.Fatal(err)
			}
			manifest := filepath.Join(install, "SHA256SUMS")
			if err := os.WriteFile(manifest, []byte("public admin staged manifest"), 0600); err != nil {
				t.Fatal(err)
			}
			for _, op := range []struct {
				name string
				fn   func() error
			}{
				{"new root child", func() error { return os.WriteFile(filepath.Join(tc.root, "plant.txt"), []byte("public"), 0600) }},
				{"new inherited install child", func() error { return os.WriteFile(filepath.Join(install, "plant.txt"), []byte("public"), 0600) }},
				{"overwrite manifest", func() error { return os.WriteFile(manifest, []byte("replacement"), 0600) }},
				{"delete manifest", func() error { return os.Remove(manifest) }},
				{"rename protected state root", func() error { return os.Rename(tc.root, filepath.Join(tc.writable, "public-renamed-state")) }},
				{"replace root DACL", func() error {
					sd, err := windows.SecurityDescriptorFromString("D:P(A;OICI;FA;;;WD)")
					if err != nil {
						return err
					}
					acl, _, err := sd.DACL()
					if err != nil {
						return err
					}
					return windows.SetNamedSecurityInfo(tc.root, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION, nil, nil, acl, nil)
				}},
			} {
				t.Run(op.name, func(t *testing.T) {
					if err := asUser(op.fn); err != windows.ERROR_ACCESS_DENIED && !os.IsPermission(err) {
						t.Fatalf("wanted actual access denial, got %v", err)
					}
				})
			}
			data, err = os.ReadFile(manifest)
			if err != nil || string(data) != "public admin staged manifest" {
				t.Fatal("protected manifest changed")
			}
			if err := tc.prepare(tc.root); err != nil {
				t.Fatalf("admin offline rerun: %v", err)
			}
			if err := os.RemoveAll(tc.root); err != nil {
				t.Fatal(err)
			}
		})
	}
}
