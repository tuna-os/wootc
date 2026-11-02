//go:build windows

package main

import (
	"context"
	"encoding/json"
	"fmt"
)

func collectHardwareDevices(ctx context.Context) ([]hardwareDevice, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	// Judge only present, working devices, like upstream's bound-driver
	// inventory. HardwareID and CompatibleID include subsystem/class IDs
	// that a device name alone cannot supply. No user data enters this script.
	out, err := runPowerShellOutput(`$ErrorActionPreference = 'Stop'
$items = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.Status -eq 'OK' -and $_.InstanceId -match '^(PCI|USB)\\' } | ForEach-Object {
  $id = $_.InstanceId
  $props = @(Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_HardwareIds','DEVPKEY_Device_CompatibleIds','DEVPKEY_Device_Service' -ErrorAction SilentlyContinue)
  $hw = @(); $compat = @(); $service = ''
  foreach ($p in $props) {
    switch ($p.KeyName) {
      'DEVPKEY_Device_HardwareIds' { $hw = @($p.Data) }
      'DEVPKEY_Device_CompatibleIds' { $compat = @($p.Data) }
      'DEVPKEY_Device_Service' { $service = [string]$p.Data }
    }
  }
  [pscustomobject]@{id=$id; name=[string]$_.FriendlyName; hardwareIds=$hw; compatibleIds=$compat; service=$service}
})
ConvertTo-Json -InputObject $items -Depth 5 -Compress`)
	if err != nil {
		return nil, fmt.Errorf("query present PCI/USB devices: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var pnp []hardwarePnPDevice
	if err := json.Unmarshal([]byte(out), &pnp); err != nil {
		return nil, fmt.Errorf("parse Windows hardware inventory: %w", err)
	}
	devices := make([]hardwareDevice, 0, len(pnp))
	for _, p := range pnp {
		devices = append(devices, hardwareFromPnP(p))
	}
	return devices, nil
}
