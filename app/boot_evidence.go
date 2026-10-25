package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"time"
)

// InstallationIdentity (install\installation.json) is retained after recovery
// removes armed.json. The first boot's record must name it and match it
// (firstboot_evidence.go checkFirstBootInstallation). A fresh
// identifier prevents a previous installation's successful boot from proving a
// new attempt. UUIDs identify the actual host volume and staged ESP.
type InstallationIdentity struct {
	SchemaVersion    int    `json:"schemaVersion"`
	InstallationID   string `json:"installationId"`
	ArmedAt          string `json:"armedAt"`
	ImageRef         string `json:"imageRef"`
	EspPartitionGuid string `json:"espPartitionGuid"`
	LoaderPath       string `json:"loaderPath"`
	HostUUID         string `json:"hostUuid"`
	RootDiskPath     string `json:"rootDiskPath"`
}

var guidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var hostUUIDPattern = regexp.MustCompile(`^[0-9a-fA-F]{16}$`)

func canonicalGUID(s string) string   { return strings.ToLower(strings.Trim(strings.TrimSpace(s), "{}")) }
func canonicalLoader(s string) string { return strings.ToLower(strings.ReplaceAll(s, "/", `\`)) }
func sourceImage(s string) string     { return strings.TrimPrefix(s, "docker://") }

func validateInstallationIdentity(p InstallationIdentity) error {
	id, err := hex.DecodeString(p.InstallationID)
	if p.SchemaVersion != 1 || err != nil || len(id) != 16 || p.InstallationID != strings.ToLower(p.InstallationID) {
		return fmt.Errorf("invalid installation identity")
	}
	if _, err := time.Parse(time.RFC3339, p.ArmedAt); err != nil {
		return fmt.Errorf("invalid arm time: %w", err)
	}
	if strings.TrimSpace(p.ImageRef) == "" || !guidPattern.MatchString(canonicalGUID(p.EspPartitionGuid)) || !hostUUIDPattern.MatchString(p.HostUUID) || p.HostUUID == strings.Repeat("0", 16) || canonicalGUID(p.EspPartitionGuid) == "00000000-0000-0000-0000-000000000000" || p.RootDiskPath != "/wootc/disks/root.disk" {
		return fmt.Errorf("incomplete installation identity")
	}
	switch canonicalLoader(p.LoaderPath) {
	case `\efi\fedora\shimx64.efi`, `\efi\systemd\shimx64.efi`, `\efi\systemd\systemd-bootx64.efi`:
	default:
		return fmt.Errorf("unrecognized installation loader")
	}
	return nil
}

func newInstallationIdentity(image, esp, loader, hostUUID string) (InstallationIdentity, error) {
	id := make([]byte, 16)
	if _, err := rand.Read(id); err != nil {
		return InstallationIdentity{}, err
	}
	p := InstallationIdentity{SchemaVersion: 1, InstallationID: hex.EncodeToString(id), ArmedAt: time.Now().UTC().Format(time.RFC3339), ImageRef: image, EspPartitionGuid: canonicalGUID(esp), LoaderPath: loader, HostUUID: strings.ToUpper(hostUUID), RootDiskPath: "/wootc/disks/root.disk"}
	return p, validateInstallationIdentity(p)
}

// Files are bounded and must contain exactly one record. Windows callers first
// verify the state tree's ownership, ACLs and absence of reparse points.
func readBootRecord(path string, record any) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 64*1024+1))
	if err != nil {
		return err
	}
	if len(data) > 64*1024 {
		return fmt.Errorf("boot record exceeds size limit")
	}
	return json.Unmarshal([]byte(strings.TrimPrefix(string(data), "\ufeff")), record)
}
