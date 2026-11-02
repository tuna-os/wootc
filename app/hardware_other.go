//go:build !windows

package main

import (
	"context"
	"fmt"
)

func collectHardwareDevices(context.Context) ([]hardwareDevice, error) {
	return nil, fmt.Errorf("Windows PnP inventory is unavailable on this host")
}
