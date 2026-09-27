package main

import (
	"encoding/hex"
	"testing"
)

const protectedHex = "0100048c48000000580000000000000014000000020034000200000000101400ff011f0001010000000000051200000000101800ff011f000102000000000005200000002002000001020000000000052000000020020000010100000000000512000000"

func protected(t *testing.T) []byte {
	t.Helper()
	sd, err := hex.DecodeString(protectedHex)
	if err != nil {
		t.Fatal(err)
	}
	return sd
}
func TestDescriptorTrust(t *testing.T) {
	if err := validateDescriptor(protected(t)); err != nil {
		t.Fatal(err)
	}
	cases := map[string]func([]byte){
		"untrusted owner":     func(sd []byte) { sd[84] = 33 },
		"untrusted write SID": func(sd []byte) { sd[47] = 1 },
		"null DACL":           func(sd []byte) { sd[16] = 0 },
		"absolute descriptor": func(sd []byte) { sd[3] &= 0x7f },
		"unknown ACE":         func(sd []byte) { sd[28] = 5 },
		"oversized ACE":       func(sd []byte) { sd[30] = 255 },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			sd := protected(t)
			mutate(sd)
			if validateDescriptor(sd) == nil {
				t.Fatal("unsafe descriptor accepted")
			}
		})
	}
	for n := 0; n < len(protectedHex)/2; n++ {
		if validateDescriptor(protected(t)[:n]) == nil {
			t.Fatalf("truncated descriptor accepted at %d", n)
		}
	}
}
