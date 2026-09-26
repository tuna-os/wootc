//go:build !windows

package main

func initializeStateTrust() error      { return nil }
func prepareInstallState(string) error { return nil }
func reportStateTrustFailure(error)    {}
