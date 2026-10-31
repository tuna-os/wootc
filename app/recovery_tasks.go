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
	RunLevel     string `json:"runLevel"`
	Trigger      string `json:"trigger"`
	ActionCount  int    `json:"actionCount"`
	TriggerCount int    `json:"triggerCount"`
}

func recoveryTaskIdentityMatches(actual, expected recoveryTaskIdentity) bool {
	return strings.EqualFold(strings.TrimSpace(actual.Name), strings.TrimSpace(expected.Name)) &&
		strings.EqualFold(strings.Trim(strings.TrimSpace(actual.Executable), `"`), strings.Trim(strings.TrimSpace(expected.Executable), `"`)) &&
		strings.TrimSpace(actual.Arguments) == strings.TrimSpace(expected.Arguments) &&
		strings.EqualFold(strings.TrimSpace(actual.Principal), strings.TrimSpace(expected.Principal)) &&
		strings.EqualFold(strings.TrimSpace(actual.RunLevel), strings.TrimSpace(expected.RunLevel)) &&
		strings.EqualFold(strings.TrimSpace(actual.Trigger), strings.TrimSpace(expected.Trigger)) &&
		actual.ActionCount == 1 &&
		actual.TriggerCount == 1
}
