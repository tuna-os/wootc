//go:build !windows

package main

import (
	"fmt"
	"os"
)

type nativeConfigurationRoot struct {
	file     *os.File
	identity os.FileInfo
}

func captureNativeConfigurationRoot(path string) (*nativeConfigurationRoot, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, fmt.Errorf("configuration root must be a regular directory")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	identity, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, err
	}
	return &nativeConfigurationRoot{file: file, identity: identity}, nil
}
func (root *nativeConfigurationRoot) close() { root.file.Close() }
func (root *nativeConfigurationRoot) matches(path string) (bool, error) {
	current, err := captureNativeConfigurationRoot(path)
	if err != nil {
		return false, err
	}
	defer current.close()
	retained, err := root.file.Stat()
	if err != nil {
		return false, err
	}
	return os.SameFile(root.identity, retained) && os.SameFile(root.identity, current.identity), nil
}
