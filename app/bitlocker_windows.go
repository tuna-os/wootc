//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// ── BitLocker state and recovery keys ─────────────────────────────────────────

// captureBitLockerRecoveryKey returns the numerical recovery password
// (48 digits) for the given volume, or "" if the volume is not BitLocker
// protected or the key cannot be extracted. The recovery password is used
// from Phase 2 (Linux) to unlock the encrypted C: drive so the User Data
// Bridge can find the user profiles that live there (#61).
func captureBitLockerRecoveryKey(vol string) string {
	// PowerShell: Get-BitLockerVolume -> KeyProtector -> RecoveryPassword.
	out, err := runPowerShellOutput(fmt.Sprintf(
		`$v = Get-BitLockerVolume -MountPoint '%s' -ErrorAction SilentlyContinue; `+
			`if (-not $v -or $v.ProtectionStatus -ne 'On') { exit 0 }; `+
			`$kp = $v.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1; `+
			`if ($kp) { Write-Output $kp.RecoveryPassword }`, vol))
	if err == nil {
		if key, err := normalizeBitLockerRecoveryPassword(out); err == nil {
			return key
		}
	}
	// Fallback: manage-bde text output.
	mb, err := runCmd("manage-bde", "-protectors", "-get", vol)
	if err != nil {
		return ""
	}
	// The numerical password line looks like:
	//   Numerical Password:
	//       ID: {GUID}
	//       Password:
	//           123456-789012-345678-901234-567890-123456-789012-123456
	re := regexp.MustCompile(`(?m)^\s*((?:[0-9]{6}-){7}[0-9]{6})\s*$`)
	m := re.FindStringSubmatch(mb)
	if m == nil {
		return ""
	}
	key, _ := normalizeBitLockerRecoveryPassword(m[1])
	return key
}

// writeBitLockerKey writes the numerical recovery password to
// <storage>:\wootc\install\bitlocker-key.txt on the selected storage drive, so Phase 2
// can read it and unlock the encrypted C: for profile discovery (#61).
// The file is ACL-restricted (SYSTEM + Administrators only). If the ACL
// cannot be applied, the key is scrubbed and not stored at all (#279): a
// recovery password that any local user can read unlocks the whole C:.
func writeBitLockerKey(key string) error {
	canonical, err := normalizeBitLockerRecoveryPassword(key)
	if err != nil {
		return err
	}
	keyPath := filepath.Join(wootcDir(), "install", "bitlocker-key.txt")
	if err := os.WriteFile(keyPath, []byte(canonical+"\n"), 0o600); err != nil {
		return fmt.Errorf("write bitlocker-key.txt: %w", err)
	}
	if err := restrictFileACL(keyPath); err != nil {
		if scrubErr := scrubFile(keyPath); scrubErr != nil {
			return fmt.Errorf("restrict bitlocker-key.txt: %w; cleanup also failed, the protected staged file must be removed before retrying: %v", err, scrubErr)
		}
		return fmt.Errorf("restrict bitlocker-key.txt; the key was scrubbed: %w", err)
	}
	return nil
}

// bitlockerState classifies a volume's encryption using
// Get-BitLockerVolume: "off" | "on" | "encrypting" | "decrypting".
// Falls back to manage-bde parsing when the cmdlet is unavailable.
func bitlockerState(vol string) string {
	out, err := runPowerShellOutput(fmt.Sprintf(
		`$v = Get-BitLockerVolume -MountPoint '%s' -ErrorAction SilentlyContinue; `+
			`if (-not $v) { 'off' } `+
			`elseif ($v.VolumeStatus -eq 'EncryptionInProgress') { 'encrypting' } `+
			`elseif ($v.VolumeStatus -eq 'DecryptionInProgress') { 'decrypting' } `+
			`elseif ($v.ProtectionStatus -eq 'On') { 'on' } `+
			`else { 'off' }`, vol))
	if err == nil {
		if s := strings.TrimSpace(out); s != "" {
			return s
		}
	}
	// Fallback: manage-bde text.
	mb, _ := runCmd("manage-bde", "-status", vol)
	switch {
	case strings.Contains(mb, "Encryption in Progress"):
		return "encrypting"
	case strings.Contains(mb, "Decryption in Progress"):
		return "decrypting"
	case strings.Contains(mb, "Protection On"):
		return "on"
	default:
		return "off"
	}
}
