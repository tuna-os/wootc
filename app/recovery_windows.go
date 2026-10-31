//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// runRecoverStartup executes the startup recovery task logic as SYSTEM.
// Evaluates the Libertix decision table and writes the atomic verdict.
func runRecoverStartup() error {
	armed, err := readArmedJSON()
	armedMissing := os.IsNotExist(err)
	if err != nil && !armedMissing {
		return fmt.Errorf("reading armed.json: %w", err)
	}
	if !armedMissing && armed.StorageDrive != "" {
		setStorageDrive(armed.StorageDrive)
	}

	// Verify executable hash if recorded (tamper protection). Any inability to
	// measure the executable is a refusal, not permission to run recovery with
	// an untrusted binary.
	if armed.ExeHash != "" {
		curExe, err := os.Executable()
		if err != nil {
			return fmt.Errorf("resolving recovery executable: %w", err)
		}
		h, err := hashFile(curExe)
		if err != nil {
			return fmt.Errorf("hashing recovery executable: %w", err)
		}
		if h != armed.ExeHash {
			return fmt.Errorf("recovery binary hash mismatch (%s != %s): refusing to run recovery", h, armed.ExeHash)
		}
	}

	_, startedErr := os.Stat(deployerStartedPath())
	startedExists := startedErr == nil

	// A healthy claim without matching first-boot evidence is still waiting
	// for its first boot, and must not retire the armed record.
	ls, ok := readVerifiedState()

	// An install that never reached its commit point (the one-shot) is
	// rolled back before anything else looks at the machine (#286).
	if handled, err := recoverBootTxnAtStartup(startedExists, ls); handled || err != nil {
		return err
	}
	if armedMissing {
		return nil // nothing armed
	}

	if !ok {
		ls = LifecycleState{State: StateArmed}
	}

	// A lifecycle word cannot authorize cleanup of the recovery controls.
	// Retain them until the installed boot is cross-checked from Windows.
	if ls.State == StateHealthy {
		if _, err := installedLinuxEvidence(armed.StorageDrive); err != nil {
			ls.State = StateDeployed
		}
	}

	verdict := EvaluateRecovery(armed, startedExists, ls, wootcDir())

	switch verdict.Verdict {
	case VerdictHealthy:
		// Completed cleanly: task removal must be confirmed before recovery
		// state is deleted, otherwise a stale task can run an old binary.
		if err := unregisterRecoveryTasks(); err != nil {
			return fmt.Errorf("cleaning recovery tasks after a healthy install: %w", err)
		}
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

// recoverBootTxnAtStartup applies bootTxnStartupAction to the boot-chain
// journal. handled is true when it rolled back an uncommitted install, which
// leaves nothing armed for the verdict table to judge. A rollback it cannot
// confirm returns an error and keeps the journal and tasks for the next start.
func recoverBootTxnAtStartup(startedExists bool, ls LifecycleState) (bool, error) {
	txn, err := readBootTxn()
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		txn = BootTxn{} // unreadable journal: never committed as far as anyone can prove
	}
	switch bootTxnStartupAction(txn, startedExists, ls) {
	case bootTxnMarkCommitted:
		// The firmware took the one-shot before the journal recorded it.
		txn.Phase = txnCommitted
		return false, writeBootTxn(txn)
	case bootTxnRollback:
		if err := rollbackBootChain(); err != nil {
			return true, err
		}
		if err := unregisterRecoveryTasks(); err != nil {
			return true, fmt.Errorf("removing recovery tasks after boot rollback: %w", err)
		}
		_ = os.Remove(filepath.Join(wootcDir(), "install", "bcd-guid.txt"))
		_ = os.Remove(armedPath())
		_ = os.Remove(verdictPath())
		writeState(StateFailed, StepInstallerMakingLinuxBootableOnYourMachine,
			"setup stopped before the boot setup was finished; "+productName()+" removed its boot entry and Windows starts normally")
		return true, nil
	}
	return false, nil
}

// recoveryTaskSpecs returns the exact task identities wootc is allowed to
// create, reuse, or remove. A task name by itself is not an ownership proof.
func recoveryTaskSpecs(exePath string) []recoveryTaskIdentity {
	return []recoveryTaskIdentity{
		{
			Name:         "wootc-recovery",
			Executable:   exePath,
			Arguments:    "recover --startup",
			Principal:    "SYSTEM",
			RunLevel:     "Highest",
			Trigger:      "MSFT_TaskBootTrigger",
			ActionCount:  1,
			TriggerCount: 1,
		},
		{
			Name:         "wootc-recovery-prompt",
			Executable:   exePath,
			Arguments:    "recover --prompt",
			Principal:    `BUILTIN\Users`,
			RunLevel:     "Highest",
			Trigger:      "MSFT_TaskLogonTrigger",
			ActionCount:  1,
			TriggerCount: 1,
		},
	}
}

func powershellLiteral(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

func queryRecoveryTask(name string) (*recoveryTaskIdentity, error) {
	script := fmt.Sprintf(`
$ErrorActionPreference = 'Stop'
$task = Get-ScheduledTask -TaskName %s -TaskPath '\' -ErrorAction SilentlyContinue
if ($null -eq $task) { exit 0 }
$actions = @($task.Actions)
$triggers = @($task.Triggers)
$action = $actions | Select-Object -First 1
$trigger = $triggers | Select-Object -First 1
$principal = "$($task.Principal.UserId)"
if ([string]::IsNullOrWhiteSpace($principal)) {
    $principal = "$($task.Principal.GroupId)"
}
[ordered]@{
    name = "$($task.TaskName)"
    executable = "$($action.Execute)"
    arguments = "$($action.Arguments)"
    principal = $principal
    runLevel = "$($task.Principal.RunLevel)"
    trigger = "$($trigger.CimClass.CimClassName)"
    actionCount = $actions.Count
    triggerCount = $triggers.Count
} | ConvertTo-Json -Compress
`, powershellLiteral(name))
	out, err := runPowerShellOutput(script)
	if err != nil {
		return nil, fmt.Errorf("querying scheduled task %q: %w (%s)", name, err, strings.TrimSpace(out))
	}
	if raw := strings.TrimSpace(out); raw != "" {
		var identity recoveryTaskIdentity
		if err := json.Unmarshal([]byte(raw), &identity); err != nil {
			return nil, fmt.Errorf("decoding scheduled task %q: %w", name, err)
		}
		return &identity, nil
	}
	return nil, nil
}

func registerScheduledTask(spec recoveryTaskIdentity) error {
	actual, err := queryRecoveryTask(spec.Name)
	if err != nil {
		return err
	}
	if actual != nil {
		if !recoveryTaskIdentityMatches(*actual, spec) {
			return fmt.Errorf("scheduled task %q exists but is not the expected recovery task; refusing to replace it", spec.Name)
		}
		return nil
	}

	var trigger, principal string
	switch spec.Trigger {
	case "MSFT_TaskBootTrigger":
		trigger = "New-ScheduledTaskTrigger -AtStartup"
	case "MSFT_TaskLogonTrigger":
		trigger = "New-ScheduledTaskTrigger -AtLogOn"
	default:
		return fmt.Errorf("unsupported recovery task trigger %q", spec.Trigger)
	}
	switch strings.ToUpper(spec.Principal) {
	case "SYSTEM":
		principal = fmt.Sprintf("New-ScheduledTaskPrincipal -UserId %s -LogonType ServiceAccount -RunLevel Highest", powershellLiteral(spec.Principal))
	default:
		principal = fmt.Sprintf("New-ScheduledTaskPrincipal -GroupId %s -RunLevel Highest", powershellLiteral(spec.Principal))
	}
	script := fmt.Sprintf(`
$ErrorActionPreference = 'Stop'
$action = New-ScheduledTaskAction -Execute %s -Argument %s
$trigger = %s
$principal = %s
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName %s -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
`, powershellLiteral(spec.Executable), powershellLiteral(spec.Arguments), trigger, principal, powershellLiteral(spec.Name))
	out, err := runPowerShellOutput(script)
	if err != nil {
		return fmt.Errorf("registering scheduled task %q: %w (%s)", spec.Name, err, strings.TrimSpace(out))
	}

	actual, err = queryRecoveryTask(spec.Name)
	if err != nil {
		return err
	}
	if actual == nil {
		return fmt.Errorf("scheduled task %q was not observable after registration", spec.Name)
	}
	if !recoveryTaskIdentityMatches(*actual, spec) {
		return fmt.Errorf("scheduled task %q did not match its requested identity after registration", spec.Name)
	}
	return nil
}

// registerRecoveryTasks registers the wootc-recovery (startup, SYSTEM) and
// wootc-recovery-prompt (logon) scheduled tasks in Windows Task Scheduler.
// Existing tasks are reused only when every security- and execution-relevant
// field matches. In particular, this never force-replaces a same-name task.
func registerRecoveryTasks(exePath string) error {
	if exePath == "" {
		var err error
		exePath, err = os.Executable()
		if err != nil {
			return fmt.Errorf("resolving executable path: %w", err)
		}
	}
	for _, spec := range recoveryTaskSpecs(exePath) {
		if err := registerScheduledTask(spec); err != nil {
			return err
		}
	}
	return nil
}

func removeScheduledTask(spec recoveryTaskIdentity) error {
	script := fmt.Sprintf(`
$ErrorActionPreference = 'Stop'
Unregister-ScheduledTask -TaskName %s -TaskPath '\' -Confirm:$false -ErrorAction Stop
if ($null -ne (Get-ScheduledTask -TaskName %s -TaskPath '\' -ErrorAction SilentlyContinue)) {
    throw 'task still exists after unregister'
}
`, powershellLiteral(spec.Name), powershellLiteral(spec.Name))
	out, err := runPowerShellOutput(script)
	if err == nil {
		return nil
	}
	// A concurrent cleanup can win the race. Confirm absence before reporting
	// the command failure; any remaining task or unreadable observation is an
	// incomplete cleanup.
	actual, queryErr := queryRecoveryTask(spec.Name)
	if queryErr == nil && actual == nil {
		return nil
	}
	if queryErr != nil {
		return fmt.Errorf("unregistering scheduled task %q: %w (%s); recheck: %v", spec.Name, err, strings.TrimSpace(out), queryErr)
	}
	return fmt.Errorf("unregistering scheduled task %q: %w (%s)", spec.Name, err, strings.TrimSpace(out))
}

// unregisterRecoveryTasks removes both recovery scheduled tasks. Missing
// tasks are already clean; foreign same-name tasks are reported and preserved.
func unregisterRecoveryTasks() error {
	exePath := filepath.Join(wootcDir(), "install", stagedEngineName)
	var failures []string
	for _, spec := range recoveryTaskSpecs(exePath) {
		actual, err := queryRecoveryTask(spec.Name)
		if err != nil {
			failures = append(failures, err.Error())
			continue
		}
		if actual == nil {
			continue
		}
		if !recoveryTaskIdentityMatches(*actual, spec) {
			failures = append(failures, fmt.Sprintf("scheduled task %q exists but is not owned by this install", spec.Name))
			continue
		}
		if err := removeScheduledTask(spec); err != nil {
			failures = append(failures, err.Error())
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf("recovery task cleanup incomplete: %s", strings.Join(failures, "; "))
	}
	return nil
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

// tryAgainFromArmed re-arms the recorded BCD entry and prepares for reboot.
func tryAgainFromArmed(noReboot bool) error {
	armed, err := readArmedJSON()
	if err != nil {
		// Fallback to persisted GUID if armed.json is missing
		return armOneShotFromPersistedGUID()
	}
	if armed.StorageDrive != "" {
		setStorageDrive(armed.StorageDrive)
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

	// Recovery must be live before the one-shot is armed. A retry that
	// re-arms first can strand Windows if task registration then fails.
	installExe := filepath.Join(wootcDir(), "install", stagedEngineName)
	if _, err := os.Stat(installExe); err != nil {
		return fmt.Errorf("recovery executable is unavailable for retry: %w", err)
	}
	if err := registerRecoveryTasks(installExe); err != nil {
		return fmt.Errorf("refreshing recovery tasks for retry: %w", err)
	}

	if out, err := runCmd("bcdedit", "/set", "{fwbootmgr}", "bootsequence", guid, "/addfirst"); err != nil {
		return fmt.Errorf("re-arming BCD bootsequence: %w (%s)", err, out)
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
//
// It inspects first and refuses whenever planBootRepair cannot attribute the
// boot chain to this install (#290), and it reports success only when a fresh
// observation shows the next boot going to the recorded wootc entry with the
// recorded ESP hashes — never because the commands returned no error.
func repairBootFromArmed(noReboot bool) error {
	before, _ := inspectBoot()
	if !before.CanRepairBoot {
		return fmt.Errorf("repair refused, nothing was changed: %s", strings.Join(before.Refusals, "; "))
	}
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
	if err := armBootChain(); err != nil {
		return fmt.Errorf("arming the repaired boot chain: %w", err)
	}

	obs := observeBoot()
	after := planBootRepair(obs)
	if err := verifyRepairArmed(after, obs); err != nil {
		// Leave Windows in charge rather than a chain we could not verify.
		// The entry, the files and armed.json stay, so the user can retry.
		if cmds, cerr := restoreWindowsCommands(after); cerr == nil {
			for _, args := range cmds {
				_, _ = runBCDEdit(args...)
			}
		}
		return fmt.Errorf("repair could not be verified, so %s was taken out of the boot order again: %w", productName(), err)
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
