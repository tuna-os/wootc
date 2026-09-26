//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// runRecoverStartup executes the startup recovery task logic as SYSTEM.
// Evaluates the Libertix decision table and writes the atomic verdict.
func runRecoverStartup() error {
	armed, err := readArmedJSON()
	if err != nil {
		if os.IsNotExist(err) {
			return nil // nothing armed
		}
		return fmt.Errorf("reading armed.json: %w", err)
	}

	// Verify executable hash if recorded (tamper protection).
	if armed.ExeHash != "" {
		curExe, err := os.Executable()
		if err == nil {
			if h, err := hashFile(curExe); err == nil && h != armed.ExeHash {
				return fmt.Errorf("recovery binary hash mismatch (%s != %s): refusing to run recovery", h, armed.ExeHash)
			}
		}
	}

	_, startedErr := os.Stat(deployerStartedPath())
	startedExists := startedErr == nil

	ls, ok := readState()
	if !ok {
		ls = LifecycleState{State: StateArmed}
	}

	verdict := EvaluateRecovery(armed, startedExists, ls, wootcDir())

	switch verdict.Verdict {
	case VerdictHealthy:
		// Completed cleanly: clean up all recovery state and tasks.
		_ = unregisterRecoveryTasks()
		_ = os.Remove(armedPath())
		_ = os.Remove(verdictPath())
		return nil

	case VerdictDeployed:
		// Phase-2 pending or booted: keep armed and write verdict.
		return writeRecoveryVerdict(verdict)

	case VerdictNeverBooted, VerdictInterrupted, VerdictFailed:
		// Disarm the one-shot bootsequence so subsequent boots stay in Windows.
		// D1/D1b rule: keep ESP files intact.
		_, _ = runCmd("bcdedit", "/deletevalue", "{fwbootmgr}", "bootsequence")
		_, _ = runCmd("bcdedit", "/enum", "{fwbootmgr}")
		return writeRecoveryVerdict(verdict)

	default:
		return writeRecoveryVerdict(verdict)
	}
}

// runRecoverPrompt displays the recovery prompt on user logon when an actionable
// verdict exists.
func runRecoverPrompt() error {
	v, err := readRecoveryVerdict()
	if err != nil {
		if os.IsNotExist(err) {
			return nil // no verdict
		}
		return err
	}
	if v.Verdict == VerdictHealthy || v.Verdict == VerdictDeployed {
		return nil
	}
	// Return nil so headless dispatcher or GUI launch handles the surface.
	return nil
}

// registerRecoveryTasks registers the wootc-recovery (startup, SYSTEM) and
// wootc-recovery-prompt (logon) scheduled tasks in Windows Task Scheduler.
func registerRecoveryTasks(exePath string) error {
	if exePath == "" {
		var err error
		exePath, err = os.Executable()
		if err != nil {
			return fmt.Errorf("resolving executable path: %w", err)
		}
	}

	// 1. Startup task: wootc-recovery (Runs as SYSTEM at startup with highest privileges)
	startupPs := fmt.Sprintf(`
$ErrorActionPreference = 'Stop'
$action = New-ScheduledTaskAction -Execute "%s" -Argument "recover --startup"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "wootc-recovery" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
`, strings.ReplaceAll(exePath, `"`, `\"`))

	if out, err := runPowerShellOutput(startupPs); err != nil {
		// Fallback to schtasks.exe if PowerShell cmdlet fails
		schCmd := fmt.Sprintf(`schtasks.exe /create /tn "wootc-recovery" /tr "\"%s\" recover --startup" /sc onstart /ru SYSTEM /rl HIGHEST /f`, exePath)
		if out2, err2 := runCmd("cmd.exe", "/c", schCmd); err2 != nil {
			return fmt.Errorf("registering wootc-recovery scheduled task: %w (ps: %s; schtasks: %s)", err, out, out2)
		}
	}

	// 2. Logon task: wootc-recovery-prompt (Runs at logon with highest privileges)
	promptPs := fmt.Sprintf(`
$ErrorActionPreference = 'Stop'
$action = New-ScheduledTaskAction -Execute "%s" -Argument "recover --prompt"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "wootc-recovery-prompt" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
`, strings.ReplaceAll(exePath, `"`, `\"`))

	if out, err := runPowerShellOutput(promptPs); err != nil {
		schCmd := fmt.Sprintf(`schtasks.exe /create /tn "wootc-recovery-prompt" /tr "\"%s\" recover --prompt" /sc onlogon /rl HIGHEST /f`, exePath)
		if out2, err2 := runCmd("cmd.exe", "/c", schCmd); err2 != nil {
			return fmt.Errorf("registering wootc-recovery-prompt scheduled task: %w (ps: %s; schtasks: %s)", err, out, out2)
		}
	}

	return nil
}

// unregisterRecoveryTasks removes both recovery scheduled tasks.
func unregisterRecoveryTasks() error {
	ps := `
Unregister-ScheduledTask -TaskName "wootc-recovery" -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "wootc-recovery-prompt" -Confirm:$false -ErrorAction SilentlyContinue
`
	_, _ = runPowerShellOutput(ps)
	_, _ = runCmd("schtasks.exe", "/delete", "/tn", "wootc-recovery", "/f")
	_, _ = runCmd("schtasks.exe", "/delete", "/tn", "wootc-recovery-prompt", "/f")
	return nil
}

// tryAgainFromArmed re-arms the recorded BCD entry and prepares for reboot.
func tryAgainFromArmed(noReboot bool) error {
	armed, err := readArmedJSON()
	if err != nil {
		// Fallback to persisted GUID file if armed.json is missing
		return armOneShotFromPersistedGUID()
	}

	guid := armed.BcdGuid
	if guid == "" {
		b, err := os.ReadFile(filepath.Join(wootcDir(), "install", "bcd-guid.txt"))
		if err == nil {
			guid = strings.TrimSpace(string(b))
		}
	}
	if !strings.HasPrefix(guid, "{") {
		return fmt.Errorf("invalid BCD GUID %q for retry", guid)
	}

	if out, err := runCmd("bcdedit", "/set", "{fwbootmgr}", "bootsequence", guid, "/addfirst"); err != nil {
		return fmt.Errorf("re-arming BCD bootsequence: %w (%s)", err, out)
	}

	// Ensure recovery tasks are fresh
	installExe := filepath.Join(wootcDir(), "install", "wootc.exe")
	if _, err := os.Stat(installExe); err == nil {
		_ = registerRecoveryTasks(installExe)
	}

	// Reset lifecycle state and markers
	writeState(StateArmed, "", "")
	_ = os.Remove(deployerStartedPath())
	_ = os.Remove(verdictPath())

	if !noReboot {
		return rebootWindows()
	}
	return nil
}

// repairBootFromArmed re-stages the ESP bootloader files and re-arms BCD.
func repairBootFromArmed(noReboot bool) error {
	armed, err := readArmedJSON()
	if err != nil {
		return fmt.Errorf("reading armed.json for repair: %w", err)
	}

	cfg := InstallConfig{
		ImageRef:     armed.ImageRef,
		StorageDrive: armed.StorageDrive,
		Bootloader:   armed.Bootloader,
	}
	if cfg.Bootloader == "" {
		cfg.Bootloader = "auto"
	}

	// Re-run setupESP and configureBCD
	if err := setupESP(cfg); err != nil {
		return fmt.Errorf("repairing ESP files: %w", err)
	}
	if err := configureBCD(cfg); err != nil {
		return fmt.Errorf("repairing BCD configuration: %w", err)
	}

	// Reset lifecycle markers
	writeState(StateArmed, "", "")
	_ = os.Remove(deployerStartedPath())
	_ = os.Remove(verdictPath())

	if !noReboot {
		return rebootWindows()
	}
	return nil
}
