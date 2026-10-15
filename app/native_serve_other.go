//go:build !windows

package main

import (
	"fmt"
	"os"
)

func runNativeServe(args []string) int {
	fmt.Fprintln(os.Stderr, "native-serve requires Windows")
	return 1
}
