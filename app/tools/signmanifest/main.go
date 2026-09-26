// signmanifest creates per-build keys and signs release manifests. Private keys
// belong in a private runner directory, never in an artifact or a source tree.
package main

import (
	"crypto/ed25519"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"wootc/internal/artifactauth"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func writeNew(path string, data []byte, mode os.FileMode) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	closeErr := f.Close()
	if err != nil {
		return err
	}
	return closeErr
}

func run(args []string) error {
	if len(args) == 3 && args[0] == "generate" {
		pub, key, err := ed25519.GenerateKey(nil)
		if err != nil {
			return err
		}
		if err = writeNew(args[1], key.Seed(), 0600); err != nil {
			return err
		}
		return writeNew(args[2], []byte(hex.EncodeToString(pub)+"\n"), 0644)
	}
	if len(args) == 4 && args[0] == "sign" {
		seed, err := os.ReadFile(args[1])
		if err != nil {
			return err
		}
		if len(seed) != ed25519.SeedSize {
			return fmt.Errorf("invalid signing seed")
		}
		data, err := os.ReadFile(args[2])
		if err != nil {
			return err
		}
		if _, err = artifactauth.Parse(data); err != nil {
			return err
		}
		return os.WriteFile(args[3], artifactauth.Sign(ed25519.NewKeyFromSeed(seed), data), 0644)
	}
	if len(args) == 4 && args[0] == "verify" {
		key, err := os.ReadFile(args[1])
		if err != nil {
			return err
		}
		data, err := os.ReadFile(args[2])
		if err != nil {
			return err
		}
		sig, err := os.ReadFile(args[3])
		if err != nil {
			return err
		}
		_, err = artifactauth.Verify(strings.TrimSpace(string(key)), data, sig)
		return err
	}
	return fmt.Errorf("usage: signmanifest generate PRIVATE_SEED PUBLIC_HEX | sign PRIVATE_SEED MANIFEST SIGNATURE | verify PUBLIC_HEX MANIFEST SIGNATURE")
}
