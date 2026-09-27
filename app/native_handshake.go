package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
)

const nativeHandshakeLimit = 16384
const nativeProtocolVersion = 1

type nativeHandshake struct {
	Kind            string `json:"kind"`
	ProtocolVersion int    `json:"protocolVersion"`
	Session         string `json:"session"`
	BuildID         string `json:"buildId"`
	BrandID         string `json:"brandId"`
}

func lowerHexLength(value string, length int) bool {
	if len(value) != length {
		return false
	}
	for _, char := range value {
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')) {
			return false
		}
	}
	return true
}

// validateNativeHandshake binds only protocol/session/package claims. It is
// deliberately not peer authentication: callers must independently retain and
// verify OS process/token identities and the protected package before any RPC.
func validateNativeHandshake(hello nativeHandshake, session, build, brand string) error {
	if hello.Kind != "hello" || hello.ProtocolVersion != nativeProtocolVersion {
		return fmt.Errorf("unsupported native handshake")
	}
	if !lowerHexLength(session, 32) || !lowerHexLength(build, 40) || brand == "" {
		return fmt.Errorf("invalid native engine session configuration")
	}
	if hello.Session != session || hello.BuildID != build || hello.BrandID != brand {
		return fmt.Errorf("native handshake differs from this session package")
	}
	return nil
}

// A single bounded JSON line precedes RPC. Preserve the reader for subsequent
// frames, reject duplicate/unknown fields, and never read unbounded peer input.
func readNativeHandshake(reader *bufio.Reader) (nativeHandshake, error) {
	var hello nativeHandshake
	line, err := reader.ReadSlice('\n')
	if err != nil {
		return hello, fmt.Errorf("native handshake line: %w", err)
	}
	if len(line) > nativeHandshakeLimit {
		return hello, fmt.Errorf("native handshake exceeds limit")
	}
	keys := json.NewDecoder(bytes.NewReader(line))
	token, err := keys.Token()
	if err != nil || token != json.Delim('{') {
		return hello, fmt.Errorf("native handshake must be an object")
	}
	seen := map[string]bool{}
	for keys.More() {
		token, err = keys.Token()
		key, ok := token.(string)
		if err != nil || !ok || seen[key] {
			return hello, fmt.Errorf("ambiguous native handshake field")
		}
		seen[key] = true
		var value json.RawMessage
		if err := keys.Decode(&value); err != nil {
			return hello, fmt.Errorf("invalid native handshake value")
		}
	}
	if _, err := keys.Token(); err != nil {
		return hello, fmt.Errorf("invalid native handshake object")
	}
	decoder := json.NewDecoder(bytes.NewReader(line))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&hello); err != nil {
		return hello, fmt.Errorf("invalid native handshake: %w", err)
	}
	var trailing json.RawMessage
	if err := decoder.Decode(&trailing); err != io.EOF {
		return hello, fmt.Errorf("trailing native handshake data")
	}
	return hello, nil
}
