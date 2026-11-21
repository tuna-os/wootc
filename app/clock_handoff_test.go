package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// The deployer reads clock.json (correct_rtc_local_clock, write_rtc_adjtime
// in deploy.sh); tests/unit/deployer-rtc-clock.bats feeds it this same
// golden, so the keys cannot drift apart.
func TestWriteClockHandoffMatchesTheDeployerGolden(t *testing.T) {
	tokyo := time.Date(2026, 11, 21, 15, 2, 52, 0, time.FixedZone("JST", 9*3600))
	root := t.TempDir()
	if err := writeClockHandoff(root, clockHandoffFor(false, "Asia/Tokyo", tokyo)); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(root, "install", "clock.json"))
	if err != nil {
		t.Fatal(err)
	}
	golden, err := os.ReadFile("../tests/unit/fixtures/clock-handoff/tokyo.json")
	if err != nil {
		t.Fatal(err)
	}
	var gotValue, wantValue map[string]any
	if err := json.Unmarshal(got, &gotValue); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(golden, &wantValue); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(gotValue, wantValue) {
		t.Fatalf("clock.json = %s, want %s", got, golden)
	}
}

// A Windows that keeps the RTC in UTC says so, and a zone west of UTC gives
// a negative offset (the deployer then moves its clock forward).
func TestClockHandoffForUniversalRTCAndWesternZones(t *testing.T) {
	newYork := time.Date(2026, 7, 1, 8, 0, 0, 0, time.FixedZone("EDT", -4*3600))
	got := clockHandoffFor(true, "America/New_York", newYork)
	want := ClockHandoff{SchemaVersion: 1, RTCLocal: false, UTCOffsetSeconds: -14400, Timezone: "America/New_York"}
	if got != want {
		t.Fatalf("clockHandoffFor = %+v, want %+v", got, want)
	}
	if got := clockHandoffFor(false, "", time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)); got.UTCOffsetSeconds != 0 || !got.RTCLocal || got.Timezone != "" {
		t.Fatalf("clockHandoffFor(UTC, unmapped) = %+v", got)
	}
}
