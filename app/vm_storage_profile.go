package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"strings"
)

// Minimums describe the helper, not the capacity needs of every OCI image.
// They never select a smaller host profile without separate image evidence.
type vmStorageMinimums struct{ Target, Scratch uint64 }
type vmStoragePlan struct{ Target, Scratch, Reserve uint64 }

func defaultVMStoragePlan() vmStoragePlan {
	return vmStoragePlan{Target: 40 << 30, Scratch: 40 << 30, Reserve: vmWindowsReserveBytes}
}

func parseVMStorageMinimums(data []byte) (vmStorageMinimums, error) {
	if len(data) > 64<<10 {
		return vmStorageMinimums{}, fmt.Errorf("helper protocol metadata exceeds size limit")
	}
	// Reject duplicate keys instead of allowing the JSON decoder's last-wins rule.
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return vmStorageMinimums{}, fmt.Errorf("invalid helper protocol object")
	}
	seen := map[string]bool{}
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return vmStorageMinimums{}, err
		}
		key, ok := token.(string)
		key = strings.ToLower(key)
		if !ok || seen[key] {
			return vmStorageMinimums{}, fmt.Errorf("duplicate or invalid helper protocol field")
		}
		seen[key] = true
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return vmStorageMinimums{}, err
		}
	}
	var protocol struct {
		SchemaVersion   int     `json:"schemaVersion"`
		Protocol        string  `json:"protocol"`
		ProtocolVersion int     `json:"protocolVersion"`
		TargetSerial    string  `json:"targetSerial"`
		ScratchSerial   string  `json:"scratchSerial"`
		Legacy          *uint64 `json:"minimumDiskBytes"`
		Target          *uint64 `json:"minimumTargetDiskBytes"`
		Scratch         *uint64 `json:"minimumScratchDiskBytes"`
	}
	if err := json.Unmarshal(data, &protocol); err != nil {
		return vmStorageMinimums{}, fmt.Errorf("invalid helper storage contract: %w", err)
	}
	if protocol.SchemaVersion != 1 || protocol.Protocol != "wootc-helper" || protocol.ProtocolVersion != 1 || protocol.TargetSerial != "wootc-root" || protocol.ScratchSerial != "wootc-scratch" {
		return vmStorageMinimums{}, fmt.Errorf("unsupported helper storage contract")
	}
	if (seen["minimumdiskbytes"] && protocol.Legacy == nil) || (seen["minimumtargetdiskbytes"] && protocol.Target == nil) || (seen["minimumscratchdiskbytes"] && protocol.Scratch == nil) {
		return vmStorageMinimums{}, fmt.Errorf("helper disk minimums cannot be null")
	}
	if (protocol.Target == nil) != (protocol.Scratch == nil) {
		return vmStorageMinimums{}, fmt.Errorf("helper disk minimums must occur as a pair")
	}
	if protocol.Legacy != nil && *protocol.Legacy == 0 {
		return vmStorageMinimums{}, fmt.Errorf("helper disk minimum must be positive")
	}
	if protocol.Target == nil {
		if protocol.Legacy == nil {
			return vmStorageMinimums{}, fmt.Errorf("helper disk minimums are missing")
		}
		return vmStorageMinimums{*protocol.Legacy, *protocol.Legacy}, nil
	}
	if *protocol.Target == 0 || *protocol.Scratch == 0 {
		return vmStorageMinimums{}, fmt.Errorf("helper disk minimums must be positive")
	}
	if protocol.Legacy != nil && (*protocol.Legacy < *protocol.Target || *protocol.Legacy < *protocol.Scratch) {
		return vmStorageMinimums{}, fmt.Errorf("legacy helper minimum is not a conservative fallback")
	}
	return vmStorageMinimums{*protocol.Target, *protocol.Scratch}, nil
}

func (plan vmStoragePlan) requiredFree(minimums vmStorageMinimums) (uint64, error) {
	if minimums.Target == 0 || minimums.Scratch == 0 || plan.Target < minimums.Target || plan.Scratch < minimums.Scratch || plan.Reserve < vmWindowsReserveBytes {
		return 0, fmt.Errorf("selected VM capacity profile does not meet the helper minimums and Windows reserve")
	}
	if plan.Target > math.MaxInt64 || plan.Scratch > math.MaxInt64 || plan.Target > math.MaxUint64-plan.Scratch || plan.Target+plan.Scratch > math.MaxUint64-plan.Reserve {
		return 0, fmt.Errorf("VM capacity profile exceeds supported disk sizes")
	}
	return plan.Target + plan.Scratch + plan.Reserve, nil
}

func (plan vmStoragePlan) admit(minimums vmStorageMinimums, available uint64) error {
	required, err := plan.requiredFree(minimums)
	if err != nil {
		return err
	}
	if available < required {
		return fmt.Errorf("VM preparation needs %.1f GiB free for its disks and Windows reserve; %.1f GiB is available", float64(required)/(1<<30), float64(available)/(1<<30))
	}
	return nil
}
