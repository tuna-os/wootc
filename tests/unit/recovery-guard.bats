#!/usr/bin/env bats
# recovery-guard.bats — unit tests for the recovery guard contract and tasks (§2)

DEPLOY_SH="payload/deployer/deploy.sh"
SETUP_PS1="tests/e2e/setup-wootc.ps1"
INSTALLER_ESP="app/installer_esp.go"
INSTALLER_WIN="app/installer_windows.go"
RECOVERY_GO="app/recovery.go"
E2E="tests/e2e/run-e2e.sh"

@test "deploy.sh contains state writes for deploying, deployed, and failed" {
    grep -q 'write_deployer_started' "$DEPLOY_SH"
    grep -q 'write_ntfs_state "deploying"' "$DEPLOY_SH"
    grep -q 'write_ntfs_state "deployed"' "$DEPLOY_SH"
    grep -q 'write_ntfs_state "failed"' "$DEPLOY_SH"
}

@test "deploy.sh contains fault injection hooks" {
    grep -q 'check_fault_injection "scratch-setup"' "$DEPLOY_SH"
    grep -q 'check_fault_injection "fisherman"' "$DEPLOY_SH"
    grep -q 'check_fault_injection "verify-complete"' "$DEPLOY_SH"
}

@test "setup-wootc.ps1 registers scheduled tasks and writes armed.json" {
    grep -q 'armed.json' "$SETUP_PS1"
    grep -q 'wootc-recovery' "$SETUP_PS1"
    grep -q 'wootc-recovery-prompt' "$SETUP_PS1"
}

@test "app writes armed.json and registers recovery tasks in configureBCD" {
    grep -q 'writeArmedJSON' "$INSTALLER_ESP"
    grep -q 'registerRecoveryTasks' "$INSTALLER_ESP"
}

@test "app unregisters recovery tasks on disarm and uninstall" {
    grep -q 'unregisterRecoveryTasks' "$INSTALLER_ESP"
    grep -q 'unregisterRecoveryTasks' "$INSTALLER_WIN"
}

@test "uninstall_check asserts recovery scheduled tasks are unregistered" {
    grep -q 'recovery scheduled tasks unregistered' "$E2E"
}

@test "decision table covers all five verdicts" {
    grep -q 'VerdictNeverBooted' "$RECOVERY_GO"
    grep -q 'VerdictInterrupted' "$RECOVERY_GO"
    grep -q 'VerdictFailed' "$RECOVERY_GO"
    grep -q 'VerdictDeployed' "$RECOVERY_GO"
    grep -q 'VerdictHealthy' "$RECOVERY_GO"
}
