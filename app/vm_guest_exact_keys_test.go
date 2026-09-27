package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestVMGuestExactSemanticKeyNames(t *testing.T) {
	for _, key := range []string{"schemaVersion", "runId", "installId", "diskId", "sessionId", "requestId", "username", "action", "serviceSha256", "ancestrySha256", "status", "bootId", "kernelRelease", "ordinarySession", "root", "desktopQualified", "editorQualified"} {
		t.Run("reply-"+key, func(t *testing.T) {
			req, reply := guestProbeFixture()
			alias := strings.ToUpper(key[:1]) + key[1:]
			reply[alias] = reply[key]
			delete(reply, key)
			raw, _ := json.Marshal(reply)
			if _, err := decodeVMGuestObservation(raw, req); err == nil {
				t.Fatal("wrong-case reply accepted")
			}
		})
	}
	for _, key := range []string{"target", "diskId", "currentRootVerified", "measurements"} {
		t.Run("root-"+key, func(t *testing.T) {
			req, reply := guestProbeFixture()
			root := reply["root"].(map[string]any)
			alias := strings.ToUpper(key[:1]) + key[1:]
			root[alias] = root[key]
			delete(root, key)
			raw, _ := json.Marshal(reply)
			if _, err := decodeVMGuestObservation(raw, req); err == nil {
				t.Fatal("wrong-case root accepted")
			}
		})
	}
}
func TestVMGuestExplicitScopeBooleans(t *testing.T) {
	for _, key := range []string{"desktopQualified", "editorQualified"} {
		t.Run(key, func(t *testing.T) {
			req, reply := guestProbeFixture()
			reply[key] = nil
			raw, _ := json.Marshal(reply)
			if _, err := decodeVMGuestObservation(raw, req); err == nil {
				t.Fatal("null scope silently accepted as false")
			}
		})
	}
}
