package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// ClockHandoff is <storage root>\wootc\install\clock.json: how Windows keeps
// the hardware clock, for the deployer and the installed system. Windows
// stores local time in the RTC unless RealTimeIsUniversal is set, and Linux
// reads the RTC as UTC by default. On a PC set to Tokyo time every deployer
// timestamp ran 9 hours ahead (probe 44869134695).
//
// UTCOffsetSeconds is Windows' offset when the install ran, DST included; the
// deployer boots minutes later and corrects its clock by it. Timezone is the
// IANA name of the Windows zone, empty when the zone has no mapping; with it
// the installed system keeps the RTC in local time as Windows does
// (/etc/adjtime LOCAL), so neither system moves the other's clock.
type ClockHandoff struct {
	SchemaVersion    int    `json:"schemaVersion"`
	RTCLocal         bool   `json:"rtcLocal"`
	UTCOffsetSeconds int    `json:"utcOffsetSeconds"`
	Timezone         string `json:"timezone"`
}

// clockHandoffFor is the record for a Windows whose RTC is (or is not) UTC,
// in the IANA zone ianaZone, at the moment now in Windows' own zone.
func clockHandoffFor(rtcUniversal bool, ianaZone string, now time.Time) ClockHandoff {
	_, offset := now.Zone()
	return ClockHandoff{SchemaVersion: 1, RTCLocal: !rtcUniversal, UTCOffsetSeconds: offset, Timezone: ianaZone}
}

// writeClockHandoff writes <root>\install\clock.json.
func writeClockHandoff(root string, handoff ClockHandoff) error {
	dir := filepath.Join(root, "install")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}
	return marshalJSONToFile(filepath.Join(dir, "clock.json"), handoff)
}
