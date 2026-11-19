//go:build windows

package privatefile

import (
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

func TestRefusePublicExistingFileWithoutMutation(t *testing.T) {
	for _, rights := range []string{"FR", "FW"} {
		t.Run(rights, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "public")
			if err := WriteNew(path, []byte("existing public bytes")); err != nil {
				t.Fatal(err)
			}
			original, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION)
			if err != nil {
				t.Fatal(err)
			}
			owner, _, err := original.Owner()
			if err != nil {
				t.Fatal(err)
			}
			sd, err := windows.SecurityDescriptorFromString("D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;" + owner.String() + ")(A;;" + rights + ";;;WD)")
			if err != nil {
				t.Fatal(err)
			}
			acl, _, err := sd.DACL()
			if err != nil {
				t.Fatal(err)
			}
			if err := windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT,
				windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil); err != nil {
				t.Fatal(err)
			}
			descriptor := func() string {
				t.Helper()
				sd, err := windows.GetNamedSecurityInfo(path, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
				if err != nil {
					t.Fatal(err)
				}
				return sd.String()
			}
			before := descriptor()
			if err := WriteFile(path, []byte("secret")); err == nil {
				t.Fatal("accepted an untrusted access grant")
			}
			if err := WriteNew(path, []byte("secret")); !os.IsExist(err) {
				t.Fatalf("exclusive create of public file = %v, want already exists", err)
			}
			data, err := os.ReadFile(path)
			if err != nil || string(data) != "existing public bytes" {
				t.Fatalf("refusal changed existing bytes: %q, %v", data, err)
			}
			if after := descriptor(); after != before {
				t.Fatalf("refusal changed the kernel descriptor: before=%s after=%s", before, after)
			}
		})
	}
}
