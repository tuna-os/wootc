//go:build windows

package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Session migration, Windows online half (docs/session-migration.md).
// The installer runs inside the user's unlocked Windows session, so DPAPI
// is available here — the one place Chromium/Electron safeStorage keys can
// be decrypted. We decrypt the app master key and stage it (re-wrapped)
// for the target, gated by per-app consent from the caller.

// SessionCandidate is a per-app finding surfaced to the GUI so the user
// can consent (or not) to moving its login.
type SessionCandidate struct {
	App        string `json:"app"`
	Kind       string `json:"kind"`       // "chromium" | "plainfile"
	Portable   bool   `json:"portable"`   // decryptable here?
	Recommend  string `json:"recommend"`  // "copy" | "relink" | "signin"
	Note       string `json:"note"`
}

// chromiumApps maps an app to its Windows User-Data root (relative to the
// profile). safeStorage layout is identical across Chromium/Electron apps.
var chromiumApps = map[string]string{
	"chrome":  `AppData\Local\Google\Chrome\User Data`,
	"edge":    `AppData\Local\Microsoft\Edge\User Data`,
	"discord": `AppData\Roaming\discord`,
	"slack":   `AppData\Roaming\Slack`,
	"spotify": `AppData\Roaming\Spotify`,
}

// dpapiUnprotect wraps CryptUnprotectData — decrypts a DPAPI blob using the
// current user's key (available because we run in their session).
func dpapiUnprotect(blob []byte) ([]byte, error) {
	var in, out windows.DataBlob
	in.Size = uint32(len(blob))
	if len(blob) > 0 {
		in.Data = &blob[0]
	}
	if err := windows.CryptUnprotectData(&in, nil, nil, 0, nil, 0, &out); err != nil {
		return nil, err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data))) //nolint:errcheck
	res := make([]byte, out.Size)
	copy(res, unsafe.Slice(out.Data, out.Size))
	return res, nil
}

// collectSessions scans the user's profile for movable sessions and writes
// a manifest for the GUI. Actual token export happens per-app only after
// the user consents (ExportSession), so nothing sensitive is written here.
func collectSessions() ([]SessionCandidate, error) {
	profile := os.Getenv("USERPROFILE")
	if profile == "" {
		return nil, fmt.Errorf("USERPROFILE not set")
	}
	var cands []SessionCandidate
	for app, rel := range chromiumApps {
		root := filepath.Join(profile, rel)
		if _, err := os.Stat(root); err != nil {
			continue
		}
		portable := chromiumKeyDecryptable(root)
		rec := "signin"
		note := "Sign in once — your data is in your account."
		if portable {
			rec = "copy"
			note = "We can carry your signed-in session across (with your OK)."
		}
		// Messengers that fingerprint devices: prefer re-link even if a
		// token copy is technically possible.
		if app == "discord" || app == "slack" {
			rec = "signin"
		}
		cands = append(cands, SessionCandidate{
			App: app, Kind: "chromium", Portable: portable, Recommend: rec, Note: note,
		})
	}

	slurpDir := filepath.Join(wootcDir(), "install", "slurp", "session")
	if err := os.MkdirAll(slurpDir, 0o755); err != nil {
		return cands, err
	}
	data, _ := marshalJSON(cands)
	_ = os.WriteFile(filepath.Join(slurpDir, "candidates.json"), data, 0o600)
	return cands, nil
}

// chromiumKeyDecryptable checks that Local State holds a DPAPI-encrypted
// os_crypt key we can actually decrypt in this session (proves online
// export will work before we promise it in the UI).
func chromiumKeyDecryptable(userDataRoot string) bool {
	ls := filepath.Join(userDataRoot, "Local State")
	raw, err := os.ReadFile(ls)
	if err != nil {
		return false
	}
	var parsed struct {
		OSCrypt struct {
			EncryptedKey string `json:"encrypted_key"`
		} `json:"os_crypt"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil || parsed.OSCrypt.EncryptedKey == "" {
		return false
	}
	keyBlob, err := base64.StdEncoding.DecodeString(parsed.OSCrypt.EncryptedKey)
	if err != nil || !strings.HasPrefix(string(keyBlob), "DPAPI") {
		return false
	}
	if _, err := dpapiUnprotect(keyBlob[5:]); err != nil {
		return false
	}
	return true
}
