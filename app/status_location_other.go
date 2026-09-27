//go:build !windows

package main

func readStatusState() (LifecycleState, bool, error) {
	state, ok := readState()
	return state, ok, nil
}
