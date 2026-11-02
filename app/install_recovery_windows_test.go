//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows/registry"
)

// The actual PowerShell guard runs against an isolated HKCU fixture. This
// observes registry ownership/refusal, not machine-wide uninstall or boot safety.
func TestUninstallRegistryOwnershipGuard(t *testing.T) {
	parentPath := fmt.Sprintf(`Software\wootc-tests-ownership-%d-%d`, os.Getpid(), time.Now().UnixNano())
	parent, existing, err := registry.CreateKey(registry.CURRENT_USER, parentPath, registry.CREATE_SUB_KEY)
	if err != nil {
		t.Fatalf("create isolated registry parent: %v", err)
	}
	if existing {
		if err := parent.Close(); err != nil {
			t.Errorf("close preexisting registry parent: %v", err)
		}
		t.Fatal("isolated registry parent already exists; refusing to use or remove it")
	}
	// Only the parent is provisioned here: the real guard must create its leaf.
	path := parentPath + `\Uninstall`
	t.Cleanup(func() {
		for _, ownedPath := range []string{path, parentPath} {
			if err := registry.DeleteKey(registry.CURRENT_USER, ownedPath); err != nil && !errors.Is(err, registry.ErrNotExist) {
				t.Errorf("remove owned registry fixture %q: %v", ownedPath, err)
			}
		}
	})
	if err := parent.Close(); err != nil {
		t.Fatalf("close isolated registry parent: %v", err)
	}
	runGuard := func(create bool) error {
		t.Helper()
		script := strings.ReplaceAll(uninstallRegistryOwnershipScript(create), uninstallRegKey, `HKCU:\`+path)
		output, err := runPowerShellOutput(script)
		if err != nil {
			const diagnosticLimit = 4096
			if len(output) > diagnosticLimit {
				output = output[:diagnosticLimit] + "\n[fixture output truncated]"
			}
			t.Logf("registry guard create=%v failed: %v\nPowerShell stdout/stderr:\n%s", create, err, output)
		}
		return err
	}
	if err := runGuard(true); err != nil {
		t.Fatal(err)
	}
	key, err := registry.OpenKey(registry.CURRENT_USER, path, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := key.Close(); err != nil {
			t.Errorf("close registry fixture leaf: %v", err)
		}
	})
	if owner, _, err := key.GetStringValue("WootcOwner"); err != nil || owner != "wootc-install-v1" {
		t.Fatalf("created key lacks ownership: %q, %v", owner, err)
	}
	if err := runGuard(true); err != nil {
		t.Fatalf("owned retry failed: %v", err)
	}
	if err := key.SetStringValue("WootcOwner", "foreign-fixture"); err != nil {
		t.Fatal(err)
	}
	for _, create := range []bool{false, true} {
		if err := runGuard(create); err == nil {
			t.Fatalf("foreign key accepted, create=%v", create)
		}
	}
	if owner, _, err := key.GetStringValue("WootcOwner"); err != nil || owner != "foreign-fixture" {
		t.Fatalf("foreign authority was changed: %q, %v", owner, err)
	}
	if err := key.DeleteValue("WootcOwner"); err != nil {
		t.Fatal(err)
	}
	for _, create := range []bool{false, true} {
		if err := runGuard(create); err == nil {
			t.Fatalf("unmarked preexisting key accepted, create=%v", create)
		}
	}
	if owner, _, err := key.GetStringValue("WootcOwner"); !errors.Is(err, registry.ErrNotExist) {
		t.Fatalf("unmarked authority was changed: %q, %v", owner, err)
	}
}
