package artifactauth

import (
	"crypto/ed25519"
	"encoding/hex"
	"strings"
	"testing"
)

func TestManifestAuthentication(t *testing.T) {
	pub, private, _ := ed25519.GenerateKey(nil)
	other, _, _ := ed25519.GenerateKey(nil)
	data := []byte(strings.Repeat("a", 64) + "  deployer-vmlinuz\n")
	signature := Sign(private, data)
	for _, tc := range []struct {
		name, key string
		data, sig []byte
		valid     bool
	}{
		{"valid", hex.EncodeToString(pub), data, signature, true},
		{"missing key", "", data, signature, false},
		{"replacement key", hex.EncodeToString(other), data, signature, false},
		{"missing signature", hex.EncodeToString(pub), data, nil, false},
		{"truncated signature", hex.EncodeToString(pub), data, signature[:63], false},
		{"edited manifest", hex.EncodeToString(pub), append(append([]byte{}, data...), '\n'), signature, false},
		{"foreign domain", hex.EncodeToString(pub), data, ed25519.Sign(private, data), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Verify(tc.key, tc.data, tc.sig)
			if (err == nil) != tc.valid {
				t.Fatalf("valid=%v err=%v", tc.valid, err)
			}
		})
	}
}

func TestRejectAuthenticatedMalformedManifest(t *testing.T) {
	pub, private, _ := ed25519.GenerateKey(nil)
	h := strings.Repeat("b", 64)
	for _, data := range []string{"", "short x", h + " ../vmlinuz", h + " /absolute", h + " share/../vmlinuz", h + " share//vmlinuz", h + " ./vmlinuz", h + " C:\\vmlinuz", h + " x\n" + h + " x", h + " file extra", strings.Repeat("x", MaxManifestSize+1)} {
		b := []byte(data)
		if _, err := Verify(hex.EncodeToString(pub), b, Sign(private, b)); err == nil {
			t.Fatalf("accepted malformed manifest size=%d", len(b))
		}
	}
}

func TestManifestCanonicalRelativeRuntimePaths(t *testing.T) {
	data := []byte(strings.Repeat("a", 64) + "  qemu/share/edk2-x86_64-code.fd\n")
	sums, err := Parse(data)
	if err != nil || sums["qemu/share/edk2-x86_64-code.fd"] == "" {
		t.Fatalf("valid runtime path: %v", err)
	}
}
