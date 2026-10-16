package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
)

// Internal read-only protocol. These observations cannot qualify a desktop.
type vmGuestProbeRequest struct {
	SchemaVersion  int    `json:"schemaVersion"`
	RunID          string `json:"runId"`
	InstallID      string `json:"installId"`
	DiskID         string `json:"diskId"`
	SessionID      string `json:"sessionId"`
	RequestID      string `json:"requestId"`
	Username       string `json:"username"`
	Action         string `json:"action"`
	ServiceSHA256  string `json:"serviceSha256"`
	AncestrySHA256 string `json:"ancestrySha256"`
}
type vmGuestProbeRoot struct {
	Target              string            `json:"target"`
	DiskID              string            `json:"diskId"`
	CurrentRootVerified bool              `json:"currentRootVerified"`
	Measurements        map[string]string `json:"measurements"`
}
type vmGuestProbeObservation struct {
	vmGuestProbeRequest
	Status           string            `json:"status"`
	BootID           string            `json:"bootId"`
	KernelRelease    string            `json:"kernelRelease"`
	OrdinarySession  map[string]string `json:"ordinarySession"`
	Root             vmGuestProbeRoot  `json:"root"`
	DesktopQualified bool              `json:"desktopQualified"`
	EditorQualified  bool              `json:"editorQualified"`
}

var vmGuestUUID = regexp.MustCompile(`^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$`)
var vmGuestSHA = regexp.MustCompile(`^[0-9a-f]{64}$`)
var vmGuestName = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)
var vmGuestIdentity = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)
var vmGuestDecimal = regexp.MustCompile(`^[1-9][0-9]{0,19}$`)

func validateVMGuestRequest(req vmGuestProbeRequest) error {
	if req.SchemaVersion != 1 || req.Action != "observe-boot-session" || !vmGuestIdentity.MatchString(req.RunID) || !vmGuestIdentity.MatchString(req.InstallID) || !vmGuestUUID.MatchString(req.DiskID) || !validDisplayDirective(req.SessionID) || !validDisplayDirective(req.RequestID) || !vmGuestName.MatchString(req.Username) || !vmGuestSHA.MatchString(req.ServiceSHA256) || !vmGuestSHA.MatchString(req.AncestrySHA256) {
		return fmt.Errorf("invalid internal guest observation request")
	}
	return nil
}
func decodeVMGuestObservation(raw []byte, expected vmGuestProbeRequest) (vmGuestProbeObservation, error) {
	var result vmGuestProbeObservation
	if err := validateVMGuestRequest(expected); err != nil {
		return result, err
	}
	if len(raw) > 256<<10 {
		return result, fmt.Errorf("guest observation exceeds bound")
	}
	fields, err := decodeQMPObject(raw)
	if err != nil || len(fields) != 17 {
		return result, fmt.Errorf("guest observation field shape unavailable")
	}
	if err = strictQMPDecode(raw, &result); err != nil {
		return result, err
	}
	if result.vmGuestProbeRequest != expected || result.Status != "observed" || !vmGuestUUID.MatchString(result.BootID) || len(result.KernelRelease) == 0 || len(result.KernelRelease) > 128 || result.DesktopQualified || result.EditorQualified {
		return result, fmt.Errorf("guest observation identity or scope mismatch")
	}
	for _, ch := range result.KernelRelease {
		if ch < 33 || ch > 126 {
			return result, fmt.Errorf("invalid current kernel release")
		}
	}
	rootFields, e := decodeQMPObject(fields["root"])
	if e != nil || len(rootFields) != 4 || !result.Root.CurrentRootVerified || result.Root.DiskID != expected.DiskID || !regexp.MustCompile(`^/dev/[A-Za-z0-9_./-]{1,128}$`).MatchString(result.Root.Target) {
		return result, fmt.Errorf("selected current guest root not observed")
	}
	session := result.OrdinarySession
	if len(session) != 10 || session["Name"] != expected.Username || session["Active"] != "yes" || session["Remote"] != "no" || session["Class"] != "user" || session["State"] != "active" || (session["Type"] != "wayland" && session["Type"] != "x11") || !vmGuestIdentity.MatchString(session["Id"]) || !vmGuestDecimal.MatchString(session["User"]) || !vmGuestDecimal.MatchString(session["Leader"]) || !vmGuestDecimal.MatchString(session["LeaderStartTicks"]) {
		return result, fmt.Errorf("ordinary current graphical session not observed")
	}
	uid, e := strconv.ParseUint(session["User"], 10, 32)
	if e != nil || uid < 1000 {
		return result, fmt.Errorf("ordinary guest user unavailable")
	}
	if len(result.Root.Measurements) != 5 {
		return result, fmt.Errorf("root measurements missing")
	}
	for _, key := range []string{"BLOCKS", "MOUNTS", "LOOPS", "PATHS", "BTRFS"} {
		value, ok := result.Root.Measurements[key]
		if !ok {
			return result, fmt.Errorf("root measurement missing")
		}
		decoded, e := base64.StdEncoding.DecodeString(value)
		if e != nil {
			return result, e
		}
		if key == "BLOCKS" || key == "MOUNTS" || key == "LOOPS" {
			var graph map[string]json.RawMessage
			graph, e = decodeQMPObject(json.RawMessage(decoded))
			if e == nil {
				field := map[string]string{"BLOCKS": "blockdevices", "MOUNTS": "filesystems", "LOOPS": "loopdevices"}[key]
				var rows []map[string]json.RawMessage
				if graph[field] == nil || json.Unmarshal(graph[field], &rows) != nil || rows == nil || (key != "LOOPS" && len(rows) == 0) {
					e = fmt.Errorf("measured graph rows unavailable")
				}
			}
			if e != nil {
				return result, fmt.Errorf("invalid measured graph: %w", e)
			}
		}
	}
	if err := verifyVMGuestRoot(result.Root, expected.DiskID); err != nil {
		return result, err
	}
	return result, nil
}
