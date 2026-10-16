package main

import (
	"bufio"
	"encoding/json"
	"strings"
	"testing"
)

func TestNativeHandshakeSessionIsolation(t *testing.T) {
	valid := nativeHandshake{Kind: "hello", ProtocolVersion: 1, Session: strings.Repeat("a", 32), BuildID: strings.Repeat("b", 40), BrandID: "wootc"}
	if err := validateNativeHandshake(valid, valid.Session, valid.BuildID, valid.BrandID); err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(*nativeHandshake){
		func(h *nativeHandshake) { h.Kind = "ready" }, func(h *nativeHandshake) { h.ProtocolVersion = 2 },
		func(h *nativeHandshake) { h.Session = strings.Repeat("c", 32) }, func(h *nativeHandshake) { h.BuildID = strings.Repeat("d", 40) },
		func(h *nativeHandshake) { h.BrandID = "other" },
	} {
		wrong := valid
		mutate(&wrong)
		if err := validateNativeHandshake(wrong, valid.Session, valid.BuildID, valid.BrandID); err == nil {
			t.Fatal("different session/package accepted")
		}
	}
	for _, session := range []string{"", strings.Repeat("A", 32), strings.Repeat("a", 31)} {
		if err := validateNativeHandshake(valid, session, valid.BuildID, valid.BrandID); err == nil {
			t.Fatal("invalid session configuration accepted")
		}
	}
}

func TestNativeHandshakeBoundsAndAmbiguity(t *testing.T) {
	valid := nativeHandshake{Kind: "hello", ProtocolVersion: 1, Session: strings.Repeat("a", 32), BuildID: strings.Repeat("b", 40), BrandID: "wootc"}
	data, _ := json.Marshal(valid)
	reader := bufio.NewReaderSize(strings.NewReader(string(data)+"\nRPC\n"), nativeHandshakeLimit)
	actual, err := readNativeHandshake(reader)
	if err != nil || actual != valid {
		t.Fatalf("valid handshake rejected: %v", err)
	}
	next, err := reader.ReadString('\n')
	if err != nil || next != "RPC\n" {
		t.Fatal("RPC frame was consumed during handshake")
	}
	for _, input := range []string{
		string(data), string(data) + " {}\n", `{"kind":"hello","kind":"hello"}` + "\n",
		`{"kind":"hello","sourceSid":"S-1-5-18"}` + "\n", `[]` + "\n", `{}` + strings.Repeat(" ", nativeHandshakeLimit) + "\n",
	} {
		if _, err := readNativeHandshake(bufio.NewReaderSize(strings.NewReader(input), nativeHandshakeLimit)); err == nil {
			t.Fatalf("unsafe handshake accepted: %.80s", input)
		}
	}
}
