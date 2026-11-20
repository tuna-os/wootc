package main

import (
	"fmt"
	"strings"
)

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

// effectiveHibernate reads the hibernation setting Windows applies from the
// {"enabled":…,"default":…} observation of HKLM\…\Control\Power that
// recordPriorPowerState takes, where "" means the value is absent. Windows
// uses HibernateEnabled when it is set and HibernateEnabledDefault otherwise;
// a machine whose hibernation was never toggled has only the default. The
// E2E guest is such a machine, and reading HibernateEnabled alone refused
// every GUI install there (runs 41575957169 and 44711120928). With neither
// value the prior state is unknown, and the install still refuses rather
// than record a guess that uninstall would later "restore".
func effectiveHibernate(observed string) (string, error) {
	var values struct {
		Enabled string `json:"enabled"`
		Default string `json:"default"`
	}
	if err := unmarshalJSON([]byte(strings.TrimSpace(observed)), &values); err != nil {
		return "", fmt.Errorf("parse hibernation settings: %w", err)
	}
	value := strings.TrimSpace(values.Enabled)
	if value == "" {
		value = strings.TrimSpace(values.Default)
	}
	if value != "0" && value != "1" {
		return "", fmt.Errorf("neither HibernateEnabled nor HibernateEnabledDefault holds 0 or 1 (%q, %q)", values.Enabled, values.Default)
	}
	return value, nil
}
