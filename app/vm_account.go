package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// VMInstallConfig contains only the choices implemented by the VM preparation
// path. Do not reuse native-install encryption/migration flags as implied promises.
type VMInstallConfig struct {
	ImageRef string `json:"imageRef"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type vmAccountInput struct {
	SchemaVersion int    `json:"schemaVersion"`
	RunID         string `json:"runId"`
	InstallID     string `json:"installId"`
	Username      string `json:"username"`
	PasswordHash  string `json:"passwordHash"`
}

var vmUsernamePattern = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)

func validateVMInstallConfig(cfg VMInstallConfig) error {
	if cfg.ImageRef == "" || strings.ContainsAny(cfg.ImageRef, " \t\r\n\x00") {
		return fmt.Errorf("select a valid operating system image")
	}
	if !vmUsernamePattern.MatchString(cfg.Username) || cfg.Username == "root" {
		return fmt.Errorf("choose a Linux username of up to 32 lowercase letters, digits, underscores or hyphens, beginning with a letter or underscore; root is reserved")
	}
	if cfg.Password == "" || len(cfg.Password) > 1024 || strings.ContainsAny(cfg.Password, "\x00\r\n") {
		return fmt.Errorf("enter a password without line breaks, up to 1024 bytes")
	}
	return nil
}

// The caller holds the image lease and has verified the directory ACL. This
// file is never an argument value containing credentials: QEMU receives only
// its protected path, through fw_cfg. No secret enters durable lifecycle JSON.
func writeVMAccountInput(root string, input vmAccountInput) (string, error) {
	if !regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{7,63}$`).MatchString(input.RunID) {
		return "", fmt.Errorf("invalid preparation run identity")
	}
	data, err := json.Marshal(input)
	if err != nil {
		return "", err
	}
	path := filepath.Join(root, ".run-account-"+input.RunID+".json")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return "", err
	}
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		os.Remove(path)
		return "", fmt.Errorf("could not stage private account input")
	}
	return path, nil
}

// Only call with the image lease: another live helper may still read its input.
// A crashed run keeps its disk and diagnostic state, but not its credential file.
func removeVMAccountInputs(root string) error {
	matches, err := filepath.Glob(filepath.Join(root, ".run-account-*.json"))
	if err != nil {
		return err
	}
	for _, path := range matches {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("could not remove private account input")
		}
	}
	return nil
}
