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

// InstallationIdentity is retained after recovery removes armed.json. A fresh
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

type LinuxBootCurrent struct {
	BootNumber       string `json:"bootNumber"`
	EspPartitionGuid string `json:"espPartitionGuid"`
	LoaderPath       string `json:"loaderPath"`
}

type LinuxRootDisk struct {
	Path     string `json:"path"`
	HostUUID string `json:"hostUuid"`
}

type LinuxBridgeBinding struct {
	Source string `json:"source"`
	Target string `json:"target"`
	User   string `json:"user"`
}

type LinuxMatchedProfile struct {
	WindowsProfile string `json:"windowsProfile"`
	LinuxUser      string `json:"linuxUser"`
	ProfileRoot    string `json:"profileRoot"`
}

type LinuxBridgeEvidence struct {
	BoundFolders      int                   `json:"boundFolders"`
	MatchedUsers      int                   `json:"matchedUsers"`
	BitlockerUnlocked bool                  `json:"bitlockerUnlocked"`
	Bindings          []LinuxBridgeBinding  `json:"bindings"`
	MatchedProfiles   []LinuxMatchedProfile `json:"matchedProfiles"`
}

// LinuxBootEvidence records observed Linux boot identity, not deployer progress.
type LinuxBootEvidence struct {
	SchemaVersion  int                 `json:"schemaVersion"`
	InstallationID string              `json:"installationId"`
	State          string              `json:"state"`
	Kernel         string              `json:"kernel"`
	Image          string              `json:"image"`
	ImageDigest    string              `json:"imageDigest"`
	SourceImageRef string              `json:"sourceImageRef"`
	BootCurrent    LinuxBootCurrent    `json:"bootCurrent"`
	RootDisk       LinuxRootDisk       `json:"rootDisk"`
	Bridge         LinuxBridgeEvidence `json:"bridge"`
	SecureBoot     bool                `json:"secureBoot"`
	FailedUnits    []string            `json:"failedUnits"`
	WrittenAt      string              `json:"writtenAt"`
	UpdatedBy      string              `json:"updatedBy"`
}

var guidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var hostUUIDPattern = regexp.MustCompile(`^[0-9a-fA-F]{16}$`)
var bootNumberPattern = regexp.MustCompile(`^[0-9a-fA-F]{4}$`)
var imageDigestPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

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

func validateLinuxBootEvidence(e LinuxBootEvidence, p InstallationIdentity, currentESP, currentHostUUID string) error {
	if err := validateInstallationIdentity(p); err != nil {
		return err
	}
	if e.SchemaVersion != 1 || e.InstallationID != p.InstallationID || e.State != StateHealthy || e.UpdatedBy != "wootc-firstboot" {
		return fmt.Errorf("boot record does not belong to this installation")
	}
	if canonicalGUID(e.BootCurrent.EspPartitionGuid) != canonicalGUID(p.EspPartitionGuid) || canonicalGUID(currentESP) != canonicalGUID(p.EspPartitionGuid) || canonicalLoader(e.BootCurrent.LoaderPath) != canonicalLoader(p.LoaderPath) || !bootNumberPattern.MatchString(e.BootCurrent.BootNumber) {
		return fmt.Errorf("boot record does not match the staged ESP and loader")
	}
	if e.RootDisk.Path != p.RootDiskPath || !strings.EqualFold(e.RootDisk.HostUUID, p.HostUUID) || !strings.EqualFold(currentHostUUID, p.HostUUID) {
		return fmt.Errorf("boot record does not match this host volume and root disk")
	}
	if strings.TrimSpace(e.Kernel) == "" || strings.TrimSpace(e.Image) == "" || !imageDigestPattern.MatchString(e.ImageDigest) || sourceImage(e.SourceImageRef) != sourceImage(p.ImageRef) {
		return fmt.Errorf("boot record has no matching image and kernel evidence")
	}
	armed, _ := time.Parse(time.RFC3339, p.ArmedAt)
	written, err := time.Parse(time.RFC3339, e.WrittenAt)
	if err != nil || written.Before(armed) {
		return fmt.Errorf("boot record predates this installation")
	}
	if e.FailedUnits == nil || len(e.FailedUnits) != 0 {
		return fmt.Errorf("boot record reports failed units or omits their result")
	}
	if e.Bridge.Bindings == nil || e.Bridge.MatchedProfiles == nil || e.Bridge.BoundFolders != len(e.Bridge.Bindings) || e.Bridge.MatchedUsers < 0 {
		return fmt.Errorf("boot record has incomplete bridge evidence")
	}
	users := map[string]bool{}
	for _, profile := range e.Bridge.MatchedProfiles {
		if profile.WindowsProfile == "" || profile.LinuxUser == "" || !strings.HasPrefix(profile.ProfileRoot, "/") {
			return fmt.Errorf("boot record has invalid matched profile")
		}
		users[profile.LinuxUser] = true
	}
	if e.Bridge.MatchedUsers != len(users) {
		return fmt.Errorf("boot record has inconsistent bridge user count")
	}
	for _, b := range e.Bridge.Bindings {
		if !strings.HasPrefix(b.Source, "/") || !strings.HasPrefix(b.Target, "/home/") || !users[b.User] {
			return fmt.Errorf("boot record has invalid bridge binding")
		}
	}
	return nil
}

// Presence matters for booleans and zero counts: omission is not a measured
// false/zero. Reject incomplete records before exposing their summary.
func (e *LinuxBootEvidence) UnmarshalJSON(data []byte) error {
	type plain LinuxBootEvidence
	var decoded plain
	if err := json.Unmarshal(data, &decoded); err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	for _, name := range []string{"schemaVersion", "installationId", "state", "kernel", "image", "imageDigest", "sourceImageRef", "bootCurrent", "rootDisk", "bridge", "secureBoot", "failedUnits", "writtenAt", "updatedBy"} {
		value, ok := fields[name]
		if !ok || string(value) == "null" {
			return fmt.Errorf("boot record omits %s", name)
		}
	}
	for object, names := range map[string][]string{"bootCurrent": {"bootNumber", "espPartitionGuid", "loaderPath"}, "rootDisk": {"path", "hostUuid"}, "bridge": {"boundFolders", "matchedUsers", "bitlockerUnlocked", "bindings", "matchedProfiles"}} {
		var nested map[string]json.RawMessage
		if err := json.Unmarshal(fields[object], &nested); err != nil {
			return err
		}
		for _, name := range names {
			v, ok := nested[name]
			if !ok || string(v) == "null" {
				return fmt.Errorf("boot record omits %s.%s", object, name)
			}
		}
	}
	*e = LinuxBootEvidence(decoded)
	return nil
}
