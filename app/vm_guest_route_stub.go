//go:build !windows

package main

import (
	"fmt"
	"os/exec"
)

func configureVMGuestChannel(cmd *exec.Cmd, state VMState, nonce string) (bool, error) {
	args, err := vmGuestRouteArgs(state, nonce)
	if err != nil {
		return false, err
	}
	if len(args) != 0 {
		return false, fmt.Errorf("managed guest observer requires Windows owned pipe transport")
	}
	return false, nil
}
func ownVMGuestObserver(cmd *exec.Cmd, enabled bool) (vmGuestTransport, error) {
	if enabled {
		return nil, fmt.Errorf("Windows observer transport unavailable")
	}
	return nil, nil
}
