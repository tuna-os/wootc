//go:build windows

package main

import "testing"

func TestNativeServeRefusesInvalidLaunchBeforeState(t *testing.T) {
	for _, args := range [][]string{
		{"engine", "--native-serve"},
		{"engine", "--native-serve", "--session", "ABC", "--source-pid", "1"},
		{"engine", "--native-serve", "--session", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--source-pid", "0"},
		{"engine", "--native-serve", "--session", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--source-pid", "4294967296"},
		{"engine", "--native-serve", "--session", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--source-pid", "1", "unexpected"},
	} {
		if code := runNativeServe(args); code != 1 {
			t.Fatal("invalid native launch was accepted")
		}
	}
}
