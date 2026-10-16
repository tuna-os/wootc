package main

import (
	"fmt"
	"runtime"
	"strings"
)

func qemuEscape(path string) string { return strings.ReplaceAll(path, ",", ",,") }
func vmResourceBudget(hostGiB float64) (memoryMiB, cpus int, err error) {
	// Keep at least half of host memory for Windows, with a 2 GiB guest floor.
	// This is an allocation bound, not a claim about desktop responsiveness.
	memoryMiB = int(hostGiB * 1024 / 2)
	if memoryMiB < 2048 {
		return 0, 0, fmt.Errorf("this VM requires at least 4 GB of host RAM; Windows must retain memory too")
	}
	if memoryMiB > 4096 {
		memoryMiB = 4096
	}
	cpus = runtime.NumCPU() - 1
	if cpus < 1 {
		cpus = 1
	}
	if cpus > 4 {
		cpus = 4
	}
	return memoryMiB, cpus, nil
}
