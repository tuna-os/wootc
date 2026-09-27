package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"strings"
)

type vmBuilderReceipt struct {
	Type               string `json:"type"`
	SchemaVersion      int    `json:"schemaVersion"`
	Status             string `json:"status"`
	RunID              string `json:"runId"`
	InstallID          string `json:"installId"`
	Image              string `json:"image"`
	DiskID             string `json:"diskId"`
	FilesystemVerified bool   `json:"filesystemVerified"`
	EFIVerified        bool   `json:"efiVerified"`
	AccountOutcome     string `json:"accountOutcome"`
	Username           string `json:"username,omitempty"`
}

func verifyVMBuilderReceipt(input io.Reader, expected VMState) (vmBuilderReceipt, error) {
	var receipt vmBuilderReceipt
	limited := &io.LimitedReader{R: input, N: (64 << 20) + 1}
	scanner := bufio.NewScanner(limited)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	count := 0
	success := false
	failed := false
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "STATUS=SUCCESS" {
			if count == 1 {
				success = true
			}
			continue
		}
		var msg struct {
			Type string `json:"type"`
			Step string `json:"step"`
		}
		if json.Unmarshal([]byte(line), &msg) != nil {
			continue
		}
		if msg.Step == "error" {
			failed = true
		}
		if msg.Type == "result" {
			count++
			if err := json.Unmarshal([]byte(line), &receipt); err != nil {
				return receipt, err
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return receipt, err
	}
	if limited.N == 0 {
		return receipt, fmt.Errorf("builder log exceeds size limit")
	}
	if failed || count != 1 || !success {
		return receipt, fmt.Errorf("builder did not supply one completed, successful installation receipt")
	}
	if receipt.SchemaVersion != 1 || receipt.Status != "success" || receipt.RunID != expected.RunID || receipt.InstallID != expected.InstallID || receipt.Image != expected.Image {
		return receipt, fmt.Errorf("builder result does not match this installation/run/image")
	}
	accountOutcome := expected.AccountOutcome
	if accountOutcome == "" {
		accountOutcome = "image-default"
	}
	if !receipt.FilesystemVerified || !receipt.EFIVerified || receipt.AccountOutcome != accountOutcome || receipt.Username != expected.Username {
		return receipt, fmt.Errorf("builder did not verify the filesystem, EFI boot, and account outcome")
	}
	diskID, err := vmDiskIdentity(expected.DiskPath)
	if err != nil {
		return receipt, err
	}
	if diskID != receipt.DiskID {
		return receipt, fmt.Errorf("builder result names a different disk identity")
	}
	return receipt, nil
}
