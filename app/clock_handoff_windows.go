//go:build windows

package main

import (
	"golang.org/x/sys/windows/registry"

	"github.com/tuna-os/wootc/slurp"
)

// windowsClock reports whether Windows keeps the hardware clock in UTC
// (RealTimeIsUniversal=1, set by people who dual-boot Linux that way) and the
// IANA name of its time zone (TimeZoneKeyName, "" when unmapped). The Windows
// default, and the answer when the value is absent or unreadable, is local
// time.
func windowsClock() (rtcUniversal bool, ianaZone string) {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SYSTEM\CurrentControlSet\Control\TimeZoneInformation`, registry.QUERY_VALUE)
	if err != nil {
		return false, ""
	}
	defer k.Close()
	if v, _, err := k.GetIntegerValue("RealTimeIsUniversal"); err == nil && v == 1 {
		rtcUniversal = true
	}
	if id, _, err := k.GetStringValue("TimeZoneKeyName"); err == nil {
		ianaZone, _ = slurp.IANAFromWindowsZone(id)
	}
	return rtcUniversal, ianaZone
}
