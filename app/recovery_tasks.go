package main

import "strings"

// recoveryTaskIdentity is the Task Scheduler metadata that makes a recovery
// task ours. Names alone are not sufficient: replacing a same-name task would
// either hijack another product's task or leave recovery pointed at the wrong
// executable.
type recoveryTaskIdentity struct {
	Name         string `json:"name"`
	Executable   string `json:"executable"`
	Arguments    string `json:"arguments"`
	Principal    string `json:"principal"`
	// PrincipalSID is the account or group the principal resolves to. Task
	// Scheduler stores a group as its SID and reports it by a local name that
	// need not be the BUILTIN\Users form wootc registered (it is localized on
	// non-English Windows), so the name alone cannot prove ownership.
	PrincipalSID string `json:"principalSid"`
	RunLevel     string `json:"runLevel"`
	Trigger      string `json:"trigger"`
	ActionCount  int    `json:"actionCount"`
	TriggerCount int    `json:"triggerCount"`
}

func recoveryTaskIdentityMatches(actual, expected recoveryTaskIdentity) bool {
	return strings.EqualFold(strings.TrimSpace(actual.Name), strings.TrimSpace(expected.Name)) &&
		strings.EqualFold(strings.Trim(strings.TrimSpace(actual.Executable), `"`), strings.Trim(strings.TrimSpace(expected.Executable), `"`)) &&
		strings.TrimSpace(actual.Arguments) == strings.TrimSpace(expected.Arguments) &&
		recoveryTaskPrincipalMatches(actual, expected) &&
		strings.EqualFold(strings.TrimSpace(actual.RunLevel), strings.TrimSpace(expected.RunLevel)) &&
		strings.EqualFold(strings.TrimSpace(actual.Trigger), strings.TrimSpace(expected.Trigger)) &&
		actual.ActionCount == 1 &&
		actual.TriggerCount == 1
}

// recoveryTaskPrincipalMatches accepts the same principal name, or the same
// SID when the scheduler reported one.
func recoveryTaskPrincipalMatches(actual, expected recoveryTaskIdentity) bool {
	if strings.EqualFold(strings.TrimSpace(actual.Principal), strings.TrimSpace(expected.Principal)) {
		return true
	}
	sid := strings.TrimSpace(actual.PrincipalSID)
	return sid != "" && strings.EqualFold(sid, strings.TrimSpace(expected.PrincipalSID))
}
