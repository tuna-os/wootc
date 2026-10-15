package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func guestProbeFixture() (vmGuestProbeRequest, map[string]any) {
	req := vmGuestProbeRequest{SchemaVersion: 1, RunID: "run", InstallID: "install", DiskID: "12345678-1234-1234-1234-123456789abc", SessionID: strings.Repeat("a", 32), RequestID: strings.Repeat("b", 32), Username: "wootc", Action: "observe-boot-session", ServiceSHA256: strings.Repeat("c", 64), AncestrySHA256: strings.Repeat("d", 64)}
	raw, _ := json.Marshal(req)
	var response map[string]any
	json.Unmarshal(raw, &response)
	response["status"] = "observed"
	response["bootId"] = req.DiskID
	response["kernelRelease"] = "6.12.1"
	response["desktopQualified"] = false
	response["editorQualified"] = false
	response["ordinarySession"] = map[string]string{"Id": "2", "User": "1000", "Name": "wootc", "Active": "yes", "Remote": "no", "Type": "wayland", "Class": "user", "State": "active", "Leader": "1234", "LeaderStartTicks": "5678"}
	blocks := base64.StdEncoding.EncodeToString([]byte(`{"blockdevices":[{"name":"/dev/vdb","type":"disk"}]}`))
	mounts := base64.StdEncoding.EncodeToString([]byte(`{"filesystems":[{"target":"/","source":"/dev/vdb3"}]}`))
	loops := base64.StdEncoding.EncodeToString([]byte(`{"loopdevices":[]}`))
	response["root"] = map[string]any{"target": "/dev/vdb", "diskId": req.DiskID, "currentRootVerified": true, "measurements": map[string]string{"BLOCKS": blocks, "MOUNTS": mounts, "LOOPS": loops, "PATHS": "", "BTRFS": ""}}
	return req, response
}
func TestVMGuestReplyIdentityAndScope(t *testing.T) {
	req, reply := guestProbeFixture()
	raw, _ := json.Marshal(reply)
	if got, err := decodeVMGuestObservation(raw, req); err != nil || got.DesktopQualified || got.EditorQualified {
		t.Fatalf("typed observation %v %v", got, err)
	}
	for key, value := range map[string]any{"runId": "old", "sessionId": strings.Repeat("f", 32), "requestId": strings.Repeat("f", 32), "serviceSha256": strings.Repeat("f", 64), "bootId": "marker", "desktopQualified": true, "editorQualified": true, "schemaVersion": true, "action": "exec", "status": "failed"} {
		t.Run(key, func(t *testing.T) {
			_, r := guestProbeFixture()
			r[key] = value
			b, _ := json.Marshal(r)
			if _, err := decodeVMGuestObservation(b, req); err == nil {
				t.Fatal("invalid reply accepted")
			}
		})
	}
	for key := range reply {
		t.Run("missing-"+key, func(t *testing.T) {
			_, r := guestProbeFixture()
			delete(r, key)
			b, _ := json.Marshal(r)
			if _, err := decodeVMGuestObservation(b, req); err == nil {
				t.Fatal("missing reply field accepted")
			}
		})
	}
	duplicated := strings.Replace(string(raw), `"schemaVersion":1`, `"schemaVersion":1,"schemaVersion":1`, 1)
	if _, err := decodeVMGuestObservation([]byte(duplicated), req); err == nil {
		t.Fatal("duplicate accepted")
	}
}
func TestVMGuestReplySessionAndRootRefusal(t *testing.T) {
	req, _ := guestProbeFixture()
	for key, value := range map[string]string{"User": "0", "Name": "other", "Active": "no", "Remote": "yes", "Type": "tty", "LeaderStartTicks": "cached", "State": "closing"} {
		t.Run(key, func(t *testing.T) {
			_, r := guestProbeFixture()
			r["ordinarySession"].(map[string]string)[key] = value
			b, _ := json.Marshal(r)
			if _, err := decodeVMGuestObservation(b, req); err == nil {
				t.Fatal("invalid ordinary session accepted")
			}
		})
	}
	for key, value := range map[string]any{"target": "cached-sentinel", "diskId": "other", "currentRootVerified": false, "measurements": map[string]string{}} {
		t.Run(key, func(t *testing.T) {
			_, r := guestProbeFixture()
			r["root"].(map[string]any)[key] = value
			b, _ := json.Marshal(r)
			if _, err := decodeVMGuestObservation(b, req); err == nil {
				t.Fatal("unavailable root accepted")
			}
		})
	}
}
