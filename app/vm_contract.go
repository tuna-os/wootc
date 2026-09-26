package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

// builderResult distinguishes a guest's explicit completion from QEMU exiting.
// A preallocated target file exists even when the guest never installed it.
type builderResult struct {
	complete bool
	failure  string
	readErr  error
}

func readBuilderProgress(input io.Reader, emit func(VMEvent)) builderResult {
	var result builderResult
	scanner := bufio.NewScanner(input)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "STATUS=SUCCESS" {
			result.complete = true
			continue
		}
		var msg struct {
			Step    string  `json:"step"`
			Pct     float64 `json:"pct"`
			Message string  `json:"msg"`
		}
		if json.Unmarshal([]byte(line), &msg) != nil || msg.Step == "" {
			continue
		}
		if msg.Step == "error" {
			result.failure = msg.Message
			if result.failure == "" {
				result.failure = "builder reported failure"
			}
		}
		emit(VMEvent{Stage: msg.Step, Percent: msg.Pct, Message: builderStepMessage(msg.Step)})
	}
	result.readErr = scanner.Err()
	return result
}

func (r builderResult) verify(processErr error) error {
	if processErr != nil {
		return fmt.Errorf("builder process failed: %w", processErr)
	}
	if r.readErr != nil {
		return fmt.Errorf("read builder result: %w", r.readErr)
	}
	if r.failure != "" {
		return fmt.Errorf("builder failed: %s", r.failure)
	}
	if !r.complete {
		return fmt.Errorf("builder exited without an explicit success result; disk is not ready")
	}
	return nil
}

func vmDiskDrive(path string) string {
	// QEMU keyval syntax escapes commas by doubling them.
	return "file=" + strings.ReplaceAll(path, ",", ",,") + ",format=raw,if=virtio"
}

func builderStepMessage(step string) string {
	switch step {
	case "pulling":
		return "Downloading the operating system image…"
	case "installing":
		return "Installing onto the Linux disk…"
	case "finalizing":
		return "Finishing up…"
	}
	return step
}
