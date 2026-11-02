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
	clear(unsafe.Slice(out.Data, out.Size))
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
			note = "Stage session keys (with your OK) — you'll sign in once on Linux."
		}
		// Messengers that fingerprint devices: prefer re-link even if a
		// token copy is technically possible.
		if app == "discord" || app == "slack" {
			rec = "signin"
		}
		cands = append(cands, SessionCandidate{
			App: app, Kind: "chromium", Portable: portable, Recommend: rec, Note: note,
			ConsentRequired: portable && rec == "copy",
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

func sessionCandidates() ([]SessionCandidate, error) {
	return collectSessions()
}

// exportSession performs only the Windows-online half of migration. It is
// intentionally impossible to call without explicit consent and a vault
// secret held in memory by the install pipeline. Discord and Slack remain
// relink-only even if their DPAPI key is readable.
func exportSession(app, vaultSecret string, consent bool) error {
	if !consent {
		return fmt.Errorf("session export for %s requires explicit consent", app)
	}
	if app == "discord" || app == "slack" {
		return fmt.Errorf("%s sessions are relink-only", app)
	}
	rel, ok := chromiumApps[app]
	if !ok {
		return fmt.Errorf("unsupported session app %q", app)
	}
	profile := os.Getenv("USERPROFILE")
	if profile == "" {
		return fmt.Errorf("USERPROFILE not set")
	}
	root := filepath.Join(profile, rel)
	key, err := chromiumMasterKey(root)
	if err != nil {
		return err
	}
	defer clear(key)
	data, err := sealSessionPayload([]byte(vaultSecret), app, key)
	if err != nil {
		return err
	}
	dir := filepath.Join(wootcDir(), "install", "slurp", "session")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	path := filepath.Join(dir, app+".enc")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return fmt.Errorf("stage %s session: %w", app, err)
	}
	if err := restrictFileACL(path); err != nil {
		_ = os.Remove(path)
		return fmt.Errorf("restrict %s session: %w", app, err)
	}
	return nil
}

func chromiumMasterKey(userDataRoot string) ([]byte, error) {
	raw, err := os.ReadFile(filepath.Join(userDataRoot, "Local State"))
	if err != nil {
		return nil, fmt.Errorf("read Chromium Local State: %w", err)
	}
	var parsed struct {
		OSCrypt struct {
			EncryptedKey string `json:"encrypted_key"`
		} `json:"os_crypt"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil || parsed.OSCrypt.EncryptedKey == "" {
		return nil, fmt.Errorf("Chromium Local State has no encrypted key")
	}
	keyBlob, err := base64.StdEncoding.DecodeString(parsed.OSCrypt.EncryptedKey)
	if err != nil || !strings.HasPrefix(string(keyBlob), "DPAPI") {
		return nil, fmt.Errorf("Chromium key is not a DPAPI key")
	}
	key, err := dpapiUnprotect(keyBlob[5:])
	if err != nil {
		return nil, fmt.Errorf("DPAPI decrypt Chromium key: %w", err)
	}
	return key, nil
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
	key, err := chromiumMasterKey(userDataRoot)
	clear(key)
	return err == nil
}
