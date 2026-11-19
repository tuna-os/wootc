package main

import (
	"crypto/aes"
	"crypto/cipher"
	"errors"
	"fmt"
)

// Windows legacy Chromium os_crypt values use AES-256-GCM:
//
//	["v10"] [12-byte nonce] [ciphertext] [16-byte GCM tag]
//
// This primitive accepts only that Windows format. Linux "v11" values use
// a different AES-CBC scheme; modern Windows app-bound "v20" values cannot
// be decrypted with the legacy key in our envelope. Do not infer a format
// from a similar prefix. Chromium Local Storage is script-controlled data,
// not a generic collection of encrypted os_crypt values.

const (
	chromiumValuePrefixLen = 3
	chromiumValueNonceLen  = 12
)

// decryptChromiumValue opens one legacy Windows Cookies encrypted_value using
// the 32-byte key recovered via DPAPI and carried in the app-bound envelope.
// Unsupported prefixes, short blobs, and bad tags fail closed. Cookie schema
// 24 domain-hash verification belongs to the caller, not this wire primitive.
func decryptChromiumValue(key []byte, blob []byte) ([]byte, error) {
	if len(key) != 32 {
		return nil, fmt.Errorf("os_crypt key must be 32 bytes, got %d", len(key))
	}
	if len(blob) < chromiumValuePrefixLen {
		return nil, errors.New("blob too short for version prefix")
	}
	prefix := string(blob[:chromiumValuePrefixLen])
	if prefix != "v10" {
		return nil, fmt.Errorf("unsupported encrypted_value prefix %q", prefix)
	}
	rest := blob[chromiumValuePrefixLen:]
	if len(rest) < chromiumValueNonceLen {
		return nil, errors.New("blob too short for nonce")
	}
	nonce, ciphertext := rest[:chromiumValueNonceLen], rest[chromiumValueNonceLen:]

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("aes cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("gcm: %w", err)
	}
	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, fmt.Errorf("open encrypted_value: %w", err)
	}
	return plaintext, nil
}
