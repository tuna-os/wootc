package main

import (
	"errors"
	"time"
)

// The server selects this projection only for the failing current configuration
// request. It cannot establish configuration success or install authority.
func nativeConfigurationFailureData(err error) any {
	var failure interface{ nativeConfigurationDiagnostic() any }
	if errors.As(err, &failure) {
		return failure.nativeConfigurationDiagnostic()
	}
	return nil
}

var nativeConfigurationPhases = []string{"root-enumeration", "initial-selection", "storage-first-query", "storage-capacity", "metadata-read", "metadata-root-audit", "catalogue-policy", "metadata-revalidation", "storage-second-query", "storage-identity-reread", "final-selection"}

type nativeConfigurationTiming struct {
	started, last time.Time
	phase         string
	durations     map[string]int64
}

func newNativeConfigurationTiming() *nativeConfigurationTiming {
	now := time.Now()
	durations := map[string]int64{}
	for _, phase := range nativeConfigurationPhases {
		durations[phase] = 0
	}
	return &nativeConfigurationTiming{started: now, last: now, phase: nativeConfigurationPhases[0], durations: durations}
}
func (t *nativeConfigurationTiming) mark(phase string) {
	now := time.Now()
	t.durations[t.phase] += now.Sub(t.last).Milliseconds()
	t.last = now
	t.phase = phase
}
func (t *nativeConfigurationTiming) finish() (string, int64, map[string]int64) {
	now := time.Now()
	t.durations[t.phase] += now.Sub(t.last).Milliseconds()
	result := map[string]int64{}
	for phase, duration := range t.durations {
		result[phase] = duration
	}
	return t.phase, now.Sub(t.started).Milliseconds(), result
}
