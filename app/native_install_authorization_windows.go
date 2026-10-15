//go:build windows

package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"sync"
)

// This authority is private to a separately authenticated install-purpose
// session. It is not an assessment capability, wire DTO or permission inferred
// from a successful profile capture. Entry-point/UI wiring is deliberately
// separate from this one-shot boundary.
type nativeInstallAuthorization struct {
	mu                     sync.Mutex
	user                   *nativeOriginalUser
	session, brand, intent string
	config                 InstallConfig
	revalidate             func() error
	used                   bool
}

type nativeInstallConfirmation struct {
	Kind            string `json:"kind"`
	ProtocolVersion int    `json:"protocolVersion"`
	Session         string `json:"session"`
	BrandID         string `json:"brandId"`
	IntentID        string `json:"intentId"`
}

func copyNativeInstallConfiguration(config InstallConfig) InstallConfig {
	if config.SessionConsent != nil {
		original := config.SessionConsent
		config.SessionConsent = make(map[string]bool, len(original))
		for id, consent := range original {
			config.SessionConsent[id] = consent
		}
	}
	return config
}

// The trusted operation adapter must validate the full configuration and bind
// revalidate to the actual selected physical volume, image/policy and user-data
// mapping. Missing validation cannot grant an authority. Confirmation never
// carries replacement config/password fields; it selects this immutable plan.
func prepareNativeInstallAuthorization(user *nativeOriginalUser, session, brand string, config InstallConfig, validate func(InstallConfig) error, revalidate func() error) (*nativeInstallAuthorization, error) {
	if user == nil || !lowerHexLength(session, 32) || brand == "" || validate == nil || revalidate == nil {
		return nil, fmt.Errorf("native install preparation unavailable")
	}
	if err := user.revalidateToken(); err != nil {
		return nil, err
	}
	owned := copyNativeInstallConfiguration(config)
	if err := validate(copyNativeInstallConfiguration(owned)); err != nil {
		return nil, fmt.Errorf("native install configuration refused")
	}
	if err := revalidate(); err != nil {
		return nil, fmt.Errorf("native install observations refused")
	}
	if err := user.revalidateToken(); err != nil {
		return nil, err
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, fmt.Errorf("native install intent unavailable")
	}
	return &nativeInstallAuthorization{user: user, session: session, brand: brand, intent: hex.EncodeToString(nonce[:]), config: owned, revalidate: revalidate}, nil
}

func decodeNativeInstallConfirmation(data []byte) (nativeInstallConfirmation, error) {
	var confirmation nativeInstallConfirmation
	if len(data) == 0 || len(data) > 4096 {
		return confirmation, fmt.Errorf("native install confirmation refused")
	}
	keys := json.NewDecoder(bytes.NewReader(data))
	token, err := keys.Token()
	if err != nil || token != json.Delim('{') {
		return confirmation, fmt.Errorf("native install confirmation refused")
	}
	allowed := map[string]bool{"kind": true, "protocolVersion": true, "session": true, "brandId": true, "intentId": true}
	seen := map[string]bool{}
	for keys.More() {
		token, err = keys.Token()
		key, ok := token.(string)
		if err != nil || !ok || !allowed[key] || seen[key] {
			return confirmation, fmt.Errorf("native install confirmation refused")
		}
		seen[key] = true
		var value json.RawMessage
		if keys.Decode(&value) != nil {
			return confirmation, fmt.Errorf("native install confirmation refused")
		}
	}
	if _, err = keys.Token(); err != nil {
		return confirmation, fmt.Errorf("native install confirmation refused")
	}
	for _, key := range []string{"kind", "protocolVersion", "session", "brandId", "intentId"} {
		if !seen[key] {
			return confirmation, fmt.Errorf("native install confirmation refused")
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&confirmation) != nil {
		return confirmation, fmt.Errorf("native install confirmation refused")
	}
	var extra json.RawMessage
	if decoder.Decode(&extra) != io.EOF {
		return confirmation, fmt.Errorf("native install confirmation refused")
	}
	return confirmation, nil
}

// Every first confirmation attempt consumes the intent, including malformed or
// mismatched payloads and a failed operation. Retrying requires a new operation
// session/plan; a changed payload cannot reuse earlier consent authority.
func (authorization *nativeInstallAuthorization) confirm(data []byte, action func(InstallConfig) error) error {
	if authorization == nil {
		return fmt.Errorf("native install authority unavailable")
	}
	authorization.mu.Lock()
	if authorization.used {
		authorization.mu.Unlock()
		return fmt.Errorf("native install intent already consumed")
	}
	authorization.used = true
	user, session, brand, intent := authorization.user, authorization.session, authorization.brand, authorization.intent
	config, revalidate := authorization.config, authorization.revalidate
	authorization.config = InstallConfig{}
	authorization.revalidate = nil
	authorization.mu.Unlock()
	confirmation, err := decodeNativeInstallConfirmation(data)
	if err != nil {
		return err
	}
	if confirmation.Kind != "confirm-install" || confirmation.ProtocolVersion != 1 || confirmation.Session != session || confirmation.BrandID != brand || confirmation.IntentID != intent || !lowerHexLength(confirmation.IntentID, 32) || action == nil {
		return fmt.Errorf("native install confirmation binding refused")
	}
	if user == nil {
		return fmt.Errorf("native install captured user unavailable")
	}
	if err := user.revalidateToken(); err != nil {
		return err
	}
	if revalidate == nil || revalidate() != nil {
		return fmt.Errorf("native install observations changed")
	}
	if err := user.revalidateToken(); err != nil {
		return err
	}
	return action(copyNativeInstallConfiguration(config))
}
