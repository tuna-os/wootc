package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestObserverBuilderArmsAuthenticatedCurrentHelper(t *testing.T) {
	metadata := observerTestMetadata(t)
	state := &VMState{RunID: "run_test123", InstallID: "install_test123", Image: "ghcr.io/example/image@sha256:" + strings.Repeat("a", 64)}
	args, err := observerBuilderKernelArgs(metadata, state)
	if err != nil {
		t.Fatal(err)
	}
	for _, token := range []string{"wootc.observer=boot-session-v1", "wootc.account_mode=create", "wootc.run_id=" + state.RunID, "wootc.install_id=" + state.InstallID, "wootc.image=" + state.Image} {
		if !strings.Contains(args, token) {
			t.Fatalf("required current helper argument absent: %s", token)
		}
	}
	for name, input := range map[string][]byte{
		"unknownMode":               bytes.Replace(metadata, []byte("boot-session-v1"), []byte("foreign"), 1),
		"wrongNamespace":            bytes.Replace(metadata, []byte("/usr/lib/wootc-observer/closure.sha256"), []byte("/var/home/user/source"), 1),
		"unisolated":                bytes.Replace(metadata, []byte(`"targetPythonIsolated": true`), []byte(`"targetPythonIsolated": false`), 1),
		"factoryAccountUnsupported": bytes.Replace(metadata, []byte("\"accountModes\": [\n      \"create\""), []byte("\"accountModes\": [\n      \"image-default\""), 1),
		"missingMetadata":           []byte(`{}`),
		"duplicateNestedMode":       bytes.Replace(metadata, []byte(`"mode": "boot-session-v1"`), []byte(`"mode":"foreign","mode":"boot-session-v1"`), 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := observerBuilderKernelArgs(input, state); err == nil {
				t.Fatal("invalid helper capability armed observer")
			}
		})
	}
	state.RunID = "foreign extra=1"
	if _, err := observerBuilderKernelArgs(metadata, state); err == nil {
		t.Fatal("foreign kernel token accepted")
	}
}

func TestObserverCapabilityCaseAliasesRefuse(t *testing.T) {
	metadata := observerTestMetadata(t)
	state := &VMState{RunID: "run_test123", InstallID: "install_test123", Image: "ghcr.io/example/image@sha256:" + strings.Repeat("a", 64)}
	cases := map[string][]byte{
		"wrongTopCase":         bytes.Replace(metadata, []byte(`"observerInstall"`), []byte(`"ObserverInstall"`), 1),
		"wrongNestedCase":      bytes.Replace(metadata, []byte(`"mode"`), []byte(`"Mode"`), 1),
		"nestedExactThenAlias": bytes.Replace(metadata, []byte(`"mode": "boot-session-v1"`), []byte(`"mode": "boot-session-v1","Mode": "boot-session-v1"`), 1),
		"nestedAliasThenExact": bytes.Replace(metadata, []byte(`"mode": "boot-session-v1"`), []byte(`"Mode": "boot-session-v1","mode": "boot-session-v1"`), 1),
	}
	for name, input := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := observerBuilderKernelArgs(input, state); err == nil {
				t.Fatal("case alias armed observer")
			}
		})
	}
}

func observerTestMetadata(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile("../payload/builder/protocol.json")
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]interface{}
	if err = json.Unmarshal(data, &envelope); err != nil {
		t.Fatal(err)
	}
	hashes := map[string]string{}
	for name, path := range map[string]string{"boot_probe.py": "../payload/vm-observer/boot_probe.py", "wootc_ancestry.py": "../tests/e2e/phase3_ancestry.py", "wootc-observer.service": "../payload/vm-observer/wootc-observer.service"} {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(raw)
		hashes[name] = hex.EncodeToString(sum[:])
	}
	envelope["observerInstall"].(map[string]interface{})["sourceHashes"] = hashes
	result, err := json.MarshalIndent(envelope, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	return result
}
