//go:build !windows

package main

import (
	"os"
)

func runRecoverStartup() error {
	armed, err := readArmedJSON()
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}

	_, startedErr := os.Stat(deployerStartedPath())
	startedExists := startedErr == nil

	ls, ok := readState()
	if !ok {
		ls = LifecycleState{State: StateArmed}
	}

	verdict := EvaluateRecovery(armed, startedExists, ls, wootcDir())
	if verdict.Verdict == VerdictHealthy {
		_ = os.Remove(armedPath())
		_ = os.Remove(verdictPath())
		return nil
	}
	return writeRecoveryVerdict(verdict)
}

func runRecoverPrompt() error {
	v, err := readRecoveryVerdict()
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if v.Verdict == VerdictHealthy || v.Verdict == VerdictDeployed {
		return nil
	}
	return nil
}

func registerRecoveryTasks(exePath string) error {
	return nil
}

func unregisterRecoveryTasks() error {
	return nil
}

func tryAgainFromArmed(noReboot bool) error {
	writeState(StateArmed, "", "")
	_ = os.Remove(deployerStartedPath())
	_ = os.Remove(verdictPath())
	return nil
}

func repairBootFromArmed(noReboot bool) error {
	writeState(StateArmed, "", "")
	_ = os.Remove(deployerStartedPath())
	_ = os.Remove(verdictPath())
	return nil
}
