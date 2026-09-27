package main

// GetInstallSteps exposes only the Windows preparation steps to the installer UI.
// The generated function returns an independent copy on every call.
func (a *App) GetInstallSteps() []StepDefinition { return InstallerSteps() }

// observedStepID accepts actual catalogue steps. Lifecycle states and recovery
// verdicts remain separate domains, including legacy values in the phase field.
func observedStepID(id string) string {
	if _, ok := StepOwner(id); ok {
		return id
	}
	return ""
}

func displayStepLabel(id string) string {
	if label, ok := StepLabel(id); ok {
		return label
	}
	return id
}

func installStepProgress(id string, percent float64) ProgressEvent {
	return ProgressEvent{Step: id, PhaseID: observedStepID(id), Message: displayStepLabel(id) + "…", Percent: percent}
}
