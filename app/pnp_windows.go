//go:build windows

package main

import (
	"encoding/json"
	"fmt"
)

// readHostHardware asks Windows for devices that are present and working, then
// translates their PnP IDs into the modalias form used by Linux modules.alias.
func readHostHardware() HostHardware {
	const script = `$devices = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop | ForEach-Object {
  [pscustomobject]@{
    pnpDeviceId = [string]$_.PNPDeviceID
    hardwareIds = @($_.HardwareID)
    compatibleIds = @($_.CompatibleID)
    service = [string]$_.Service
    name = [string]$_.Name
    pnpClass = [string]$_.PNPClass
    manufacturer = [string]$_.Manufacturer
    status = [string]$_.Status
    configManagerErrorCode = [uint32]$_.ConfigManagerErrorCode
  }
})
ConvertTo-Json -InputObject $devices -Compress -Depth 4`
	output, err := runPowerShellOutput(script)
	if err != nil {
		return hostHardwareFromPnP(nil, false, fmt.Sprintf("Windows could not list Plug and Play devices: %v", err))
	}
	var records []pnpRecord
	if err := json.Unmarshal([]byte(output), &records); err != nil {
		return hostHardwareFromPnP(nil, false, fmt.Sprintf("Windows returned an unreadable Plug and Play inventory: %v", err))
	}
	return hostHardwareFromPnP(records, true, "")
}
