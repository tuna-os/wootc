//go:build windows

package main

import (
	"crypto/rand"
	"fmt"
	"os"
	"path/filepath"

	"github.com/tredoe/osutil/user/crypt/sha512_crypt"
)

// ── Password hashing ─────────────────────────────────────────────────────────
// Uses SHA-512 crypt ($6$) — universally compatible across all Linux distros.
// yescrypt ($y$) support can be added later for Fedora/RHEL targets via CGo
// linking against libcrypt, but SHA-512 works everywhere and is the safe default.

const (
	saltBytes = 16
	saltChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./"
)

// hashPassword returns a $6$<salt>$<hash> string suitable for /etc/shadow.
// The salt is randomly generated using crypto/rand.
func hashPassword(password string) (string, error) {
	if password == "" {
		return "", fmt.Errorf("password must not be empty")
	}

	// Generate a random 16-byte salt, then encode as base64-like chars
	salt := make([]byte, saltBytes)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("random salt: %w", err)
	}
	saltStr := make([]byte, saltBytes)
	for i, b := range salt {
		saltStr[i] = saltChars[int(b)%len(saltChars)]
	}

	// sha512_crypt.Generate requires the salt to carry the $6$ magic
	// prefix (it returns "invalid magic prefix" otherwise — caught by the
	// Phase-1 E2E on first real run).
	c := sha512_crypt.New()
	hash, err := c.Generate([]byte(password), []byte("$6$"+string(saltStr)))
	if err != nil {
		return "", fmt.Errorf("sha512-crypt: %w", err)
	}

	return hash, nil
}

// ── vault.json writer ────────────────────────────────────────────────────────

// writeVault writes C:\wootc\install\vault.json with the hashed credential.
// The plaintext password never touches disk — only the hash is persisted.
// ACL is restricted to SYSTEM and Administrators only.
func writeVault(cfg InstallConfig) error {
	if cfg.Password == "" {
		return fmt.Errorf("password must not be empty")
	}

	hash, err := hashPassword(cfg.Password)
	if err != nil {
		return fmt.Errorf("hash password: %w", err)
	}

	vault := map[string]string{
		"username":      cfg.Username,
		"hostname":      cfg.Hostname,
		"image":         cfg.ImageRef,
		"password_hash": hash,
	}

	data, err := marshalJSON(vault)
	if err != nil {
		return err
	}

	vaultPath := filepath.Join(wootcDir(), "install", "vault.json")
	if err := os.WriteFile(vaultPath, data, 0o600); err != nil {
		return fmt.Errorf("write vault.json: %w", err)
	}

	// Restrict ACL: only SYSTEM and Administrators
	if err := restrictFileACL(vaultPath); err != nil {
		// Non-fatal: ACL restriction is a defense-in-depth best-effort measure.
		// The file is already in a directory only accessible to admins.
		fmt.Fprintf(os.Stderr, "[wootc] warning: ACL restriction failed for vault.json: %v\n", err)
	}

	return nil
}
