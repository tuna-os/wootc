package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"time"
)

type StoragePartitionReceipt struct {
	SchemaVersion        int    `json:"schemaVersion"`
	PartitionGUID        string `json:"partitionGuid"`
	DiskGUID             string `json:"diskGuid"`
	SourceCPartitionGUID string `json:"sourceCPartitionGuid"`
	SourceCDiskGUID      string `json:"sourceCDiskGuid"`
	SizeBytes            uint64 `json:"sizeBytes"`
	CreatedAt            string `json:"createdAt"`
}

var partitionReceiptGUID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func (r StoragePartitionReceipt) validate() error {
	if r.SchemaVersion != 1 || r.SizeBytes == 0 {
		return fmt.Errorf("invalid partition creation receipt schema or size")
	}
	for _, guid := range []string{r.PartitionGUID, r.DiskGUID, r.SourceCPartitionGUID, r.SourceCDiskGUID} {
		if !partitionReceiptGUID.MatchString(guid) || guid == "00000000-0000-0000-0000-000000000000" {
			return fmt.Errorf("invalid stable GPT identity in partition creation receipt")
		}
	}
	if r.PartitionGUID == r.SourceCPartitionGUID || r.DiskGUID != r.SourceCDiskGUID {
		return fmt.Errorf("partition receipt does not identify a dedicated partition on the original Windows disk")
	}
	if _, err := time.Parse(time.RFC3339Nano, r.CreatedAt); err != nil {
		return fmt.Errorf("invalid partition creation timestamp")
	}
	return nil
}

func decodeStoragePartitionReceipt(data []byte) (StoragePartitionReceipt, error) {
	var receipt StoragePartitionReceipt
	if len(data) > 4096 {
		return receipt, fmt.Errorf("partition creation receipt too large")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&receipt); err != nil {
		return receipt, err
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return receipt, fmt.Errorf("partition receipt has trailing JSON")
	}
	return receipt, receipt.validate()
}

func persistNewStoragePartitionReceipt(path string, receipt StoragePartitionReceipt) error {
	if err := receipt.validate(); err != nil {
		return err
	}
	data, err := json.Marshal(receipt)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return fmt.Errorf("retain partition creation receipt without replacing prior ownership: %w", err)
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

func partitionReceiptPowerShell(receipt StoragePartitionReceipt) (string, error) {
	if err := receipt.validate(); err != nil {
		return "", err
	}
	data, err := json.Marshal(receipt)
	if err != nil {
		return "", err
	}
	encoded := base64.StdEncoding.EncodeToString(data)
	return "$receipt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + encoded + "')) | ConvertFrom-Json\n", nil
}

// Completion remains the final authority while earlier receipt cleanup runs.
// The read callback applies the platform's protected-file audit in production.
func finalizeStoragePartitionRemoval(path string, receipt StoragePartitionReceipt, read func(string) (StoragePartitionReceipt, error), remove func(string) error) error {
	complete, err := read(path + ".complete")
	if err != nil {
		if !os.IsNotExist(err) {
			return err
		}
		deleted, err := read(path + ".deleted")
		if err != nil {
			return err
		}
		if deleted != receipt {
			return fmt.Errorf("deletion receipt does not match completed identity")
		}
		if err := persistNewStoragePartitionReceipt(path+".complete", receipt); err != nil {
			return err
		}
	} else if complete != receipt {
		return fmt.Errorf("completion receipt does not match creation identity")
	}
	for _, suffix := range []string{".removal", ".deleted", ""} {
		if err := remove(path + suffix); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return remove(path + ".complete")
}
