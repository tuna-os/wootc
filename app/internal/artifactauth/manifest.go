// Package artifactauth authenticates the exact release manifest before parsing it.
package artifactauth

import (
	"crypto/ed25519"
	"encoding/hex"
	"fmt"
	"path"
	"strings"
)

const MaxManifestSize = 256 * 1024
const domain = "wootc boot-artifact manifest v1\x00"

func Sign(key ed25519.PrivateKey, data []byte) []byte {
	return ed25519.Sign(key, append([]byte(domain), data...))
}

func Verify(publicKey string, data, signature []byte) (map[string]string, error) {
	key, err := hex.DecodeString(publicKey)
	if err != nil || len(key) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("installer has no valid embedded artifact verification key")
	}
	if len(data) > MaxManifestSize || !ed25519.Verify(key, append([]byte(domain), data...), signature) {
		return nil, fmt.Errorf("boot-artifact manifest signature is invalid")
	}
	return Parse(data)
}

// Parse rejects ambiguous hashes and names even in an authentic manifest.
func Parse(data []byte) (map[string]string, error) {
	if len(data) == 0 || len(data) > MaxManifestSize {
		return nil, fmt.Errorf("invalid manifest size")
	}
	sums := make(map[string]string)
	for i, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != 2 {
			return nil, fmt.Errorf("invalid manifest line %d", i+1)
		}
		hash, err := hex.DecodeString(fields[0])
		name := strings.TrimPrefix(fields[1], "*")
		if err != nil || len(hash) != 32 || name == "" || name == "." || name == ".." || strings.ContainsAny(name, "\\:\x00") || path.IsAbs(name) || path.Clean(name) != name || strings.HasPrefix(name, "../") {
			return nil, fmt.Errorf("invalid manifest entry at line %d", i+1)
		}
		if _, exists := sums[name]; exists {
			return nil, fmt.Errorf("duplicate manifest entry %q", name)
		}
		sums[name] = strings.ToLower(fields[0])
	}
	if len(sums) == 0 {
		return nil, fmt.Errorf("empty manifest")
	}
	return sums, nil
}
