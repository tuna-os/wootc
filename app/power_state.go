package main

import "strings"

// Pre-install power state, parsed here rather than in the Windows-only prober
// so it builds — and is tested — everywhere. The install turns hibernation and
// Fast Startup off; uninstall's promise is to put back exactly what was there,
// which means the recorded values have to survive the uninstall and be read
// back unambiguously.

// parsePriorPower reads the `hibernate=<n>\nhiberboot=<n>` record written by
// recordPriorPowerState. Unknown keys and blank lines are ignored; a missing
// key yields "" so callers can tell "was off" (0) from "never recorded" ("").
//
// The previous reader was `strings.Contains(content, "hibernate=1")`, which
// cannot make that distinction and matches "hibernate=10" as well. Restoration
// is a promise about the user's machine, so it reads the value rather than
// looking for a substring of it.
func parsePriorPower(content string) (hibernate, hiberboot string) {
	for _, line := range strings.Split(content, "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if !ok {
			continue
		}
		switch strings.TrimSpace(key) {
		case "hibernate":
			hibernate = strings.TrimSpace(value)
		case "hiberboot":
			hiberboot = strings.TrimSpace(value)
		}
	}
	return hibernate, hiberboot
}
