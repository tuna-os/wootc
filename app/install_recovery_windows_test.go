//go:build windows

package main

import (
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
	path := fmt.Sprintf(`Software\wootc-tests\ownership-%d-%d`, os.Getpid(), time.Now().UnixNano())
	defer registry.DeleteKey(registry.CURRENT_USER, path)
	script := func(create bool) string {
		return strings.ReplaceAll(uninstallRegistryOwnershipScript(create), uninstallRegKey, `HKCU:\`+path)
	}
	if err := runPowerShell(script(true)); err != nil {
		t.Fatal(err)
	}
	key, err := registry.OpenKey(registry.CURRENT_USER, path, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		t.Fatal(err)
	}
	defer key.Close()
	if owner, _, err := key.GetStringValue("WootcOwner"); err != nil || owner != "wootc-install-v1" {
		t.Fatalf("created key lacks ownership: %q, %v", owner, err)
	}
	if err := runPowerShell(script(true)); err != nil {
		t.Fatalf("owned retry failed: %v", err)
	}
	if err := key.SetStringValue("WootcOwner", "foreign-fixture"); err != nil {
		t.Fatal(err)
	}
	for _, create := range []bool{false, true} {
		if err := runPowerShell(script(create)); err == nil {
			t.Fatalf("foreign key accepted, create=%v", create)
		}
	}
	if owner, _, err := key.GetStringValue("WootcOwner"); err != nil || owner != "foreign-fixture" {
		t.Fatalf("foreign authority was changed: %q, %v", owner, err)
	}
	if err := key.DeleteValue("WootcOwner"); err != nil {
		t.Fatal(err)
	}
	if err := runPowerShell(script(true)); err == nil {
		t.Fatal("unmarked preexisting key accepted")
	}
}
