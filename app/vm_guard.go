package main

import (
	"fmt"
	"os"
	"path/filepath"
)

func vmStatePath(root string) string { return filepath.Join(root, "vm", "state.json") }

// Native install must not turn VM-first into a fresh deployment of the same
// disk. Promotion needs its separate verified transition; until then refuse.
func acquireNativeInstallLease(root string) (func(), error) {
	release, err := acquireVMLock(filepath.Join(root, "disks", "root.disk"))
	if err != nil {
		return nil, err
	}
	if _, err = os.Lstat(vmStatePath(root)); !os.IsNotExist(err) {
		release()
		if err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("this disk belongs to a managed VM; native promotion must preserve that system and is not available yet")
	}
	if err = verifyVMDiskReleased(filepath.Join(root, "disks", "root.disk")); err != nil {
		release()
		return nil, err
	}
	return release, nil
}
