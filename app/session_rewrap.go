package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"

	"golang.org/x/crypto/hkdf"
)

// Session rewrap primitives (docs/session-migration.md): shared by the
// Windows DPAPI exporter and the explicit-password Linux envelope consumer.
//
// Format: [version(1) | salt(32) | nonce(12) | ciphertext+tag]. The key is
// derived from the vault secret, app name, and the per-envelope salt, then
// sealed with AES-256-GCM. The app name is associated data, so a blob cannot
// be relabeled for another app without failing authentication.

const sessionRewrapVersion = 1

// deriveRewrapKey derives a 32-byte AES-256 key from the vault secret,
// scoped to a single app via HKDF's info parameter. Per-app scoping means
// a leaked key for one app's staged blob doesn't expose another app's.
func deriveRewrapKey(vaultSecret []byte, app string) ([]byte, error) {
	return deriveRewrapKeyWithSalt(vaultSecret, app, nil)
}

func deriveRewrapKeyWithSalt(vaultSecret []byte, app string, salt []byte) ([]byte, error) {
	if len(vaultSecret) == 0 {
		return nil, errors.New("vault secret must not be empty")
	}
	if app == "" {
		return nil, errors.New("app must not be empty")
	}
	h := hkdf.New(sha256.New, vaultSecret, salt, []byte("wootc-session-rewrap-v1:"+app))
	key := make([]byte, 32)
	if _, err := io.ReadFull(h, key); err != nil {
		return nil, fmt.Errorf("derive rewrap key: %w", err)
	}
	return key, nil
}

// sealSessionPayload encrypts plaintext under a vault secret and app name,
// producing the versioned envelope described above. Staged as
// install\slurp\session\<app>.enc by the caller.
func sealSessionPayload(vaultSecret []byte, app string, plaintext []byte) ([]byte, error) {
	salt := make([]byte, 32)
	if _, err := rand.Read(salt); err != nil {
		return nil, fmt.Errorf("salt: %w", err)
	}
	key, err := deriveRewrapKeyWithSalt(vaultSecret, app, salt)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("aes cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("gcm: %w", err)
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("nonce: %w", err)
	}
	out := make([]byte, 0, 1+len(salt)+len(nonce)+len(plaintext)+gcm.Overhead())
	out = append(out, sessionRewrapVersion)
	out = append(out, salt...)
	out = append(out, nonce...)
	out = gcm.Seal(out, nonce, plaintext, []byte(app))
	return out, nil
}

// openSessionPayload reverses sealSessionPayload using the vault secret and
// app identity. Used by the target-side rewrite and tests.
func openSessionPayload(vaultSecret []byte, app string, blob []byte) ([]byte, error) {
	if len(blob) < 1 {
		return nil, errors.New("blob too short")
	}
	if blob[0] != sessionRewrapVersion {
		return nil, fmt.Errorf("unsupported session payload version %d", blob[0])
	}
	if len(blob) < 1+32 {
		return nil, errors.New("blob too short for salt")
	}
	salt := blob[1 : 1+32]
	key, err := deriveRewrapKeyWithSalt(vaultSecret, app, salt)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("aes cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("gcm: %w", err)
	}
	ns := gcm.NonceSize()
	rest := blob[1+32:]
	if len(rest) < ns {
		return nil, errors.New("blob too short for nonce")
	}
	nonce, ciphertext := rest[:ns], rest[ns:]
	plaintext, err := gcm.Open(nil, nonce, ciphertext, []byte(app))
	if err != nil {
		return nil, fmt.Errorf("open: %w", err)
	}
	return plaintext, nil
}
