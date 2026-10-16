package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// Native assessment streams directory entries rather than allocating an
// arbitrarily large directory listing. Every object must pass the same trust
// inspector; limits refuse the tree, never accept a partial audit.
func auditNativeStatusTree(ctx context.Context, root string, limit int, inspect func(string) error) error {
	count := 0
	var walk func(string) error
	walk = func(path string) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		count++
		if count > limit {
			return fmt.Errorf("native status tree exceeds audit bound")
		}
		if err := inspect(path); err != nil {
			return err
		}
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		if !info.IsDir() {
			return nil
		}
		directory, err := os.Open(path)
		if err != nil {
			return err
		}
		defer directory.Close()
		opened, err := directory.Stat()
		if err != nil {
			return err
		}
		if !os.SameFile(info, opened) {
			return fmt.Errorf("native status directory changed")
		}
		for {
			if err := ctx.Err(); err != nil {
				return err
			}
			entries, err := directory.ReadDir(64)
			for _, entry := range entries {
				if err := walk(filepath.Join(path, entry.Name())); err != nil {
					return err
				}
			}
			if err == io.EOF {
				return nil
			}
			if err != nil {
				return err
			}
		}
	}
	return walk(root)
}
