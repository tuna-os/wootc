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
		key := strings.TrimSpace(out)
		key = strings.ReplaceAll(key, "-", "")
		if len(key) == 48 {
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
	re := regexp.MustCompile(`(?m)^\s*Password:\s*$\s*^\s*([0-9-]{55})\s*$`)
	m := re.FindStringSubmatch(mb)
	if m == nil {
		return ""
	}
	key := strings.ReplaceAll(m[1], "-", "")
	if len(key) == 48 {
		return key
	}
	return ""
}

// writeBitLockerKey writes the numerical recovery password to
// C:\wootc\install\bitlocker-key.txt on the storage drive, so Phase 2
// can read it and unlock the encrypted C: for profile discovery (#61).
// The file is ACL-restricted (SYSTEM + Administrators only).
func writeBitLockerKey(key string) error {
	keyPath := filepath.Join(wootcDir(), "install", "bitlocker-key.txt")
	if err := os.WriteFile(keyPath, []byte(key+"\n"), 0o600); err != nil {
		return fmt.Errorf("write bitlocker-key.txt: %w", err)
	}
	if err := restrictFileACL(keyPath); err != nil {
		fmt.Fprintf(os.Stderr, "[wootc] warning: ACL restriction failed for bitlocker-key.txt: %v\n", err)
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
