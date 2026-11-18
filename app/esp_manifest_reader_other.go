//go:build !windows

package main

import "os"

func openESPManifest(path string) (*os.File, error) {
	return os.Open(path)
}
