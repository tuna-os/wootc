package main

import (
	"os"
	"strings"
	"testing"
)

// The installer and its boot artifacts (deployer kernel, initramfs, signed
// shim) are cut by one release job and gated by one E2E run. An exe that
// fetches from `latest` runs whatever is newest today — a deployer it was
// never tested with — and SHA256SUMS cannot catch it, because the manifest
// comes from the same moved release: mismatched-but-consistent artifacts
// verify perfectly (#335).

func TestDeployerBaseURLPinsTheReleaseItWasCutFrom(t *testing.T) {
	oldTag, oldMirror := releaseTag, os.Getenv("WOOTC_DEPLOYER_MIRROR")
	t.Cleanup(func() {
		releaseTag = oldTag
		_ = os.Setenv("WOOTC_DEPLOYER_MIRROR", oldMirror)
	})
	_ = os.Unsetenv("WOOTC_DEPLOYER_MIRROR")

	releaseTag = "v0.2.0-alpha.3"
	got := deployerBaseURL()
	want := "https://github.com/tuna-os/wootc/releases/download/v0.2.0-alpha.3/"
	if got != want {
		t.Fatalf("deployerBaseURL() = %q, want %q", got, want)
	}
	if strings.Contains(got, "/latest/") {
		t.Fatal("a stamped build must never fetch from latest")
	}
}

func TestDeployerBaseURLFallsBackForAnUnstampedBuild(t *testing.T) {
	// A developer's `go build` has no release to pin to. Refusing to run
	// would make the tree unusable locally; `latest` is the only honest
	// answer available to it.
	oldTag, oldMirror := releaseTag, os.Getenv("WOOTC_DEPLOYER_MIRROR")
	t.Cleanup(func() {
		releaseTag = oldTag
		_ = os.Setenv("WOOTC_DEPLOYER_MIRROR", oldMirror)
	})
	_ = os.Unsetenv("WOOTC_DEPLOYER_MIRROR")

	releaseTag = ""
	if got := deployerBaseURL(); got != "https://github.com/tuna-os/wootc/releases/latest/download/" {
		t.Fatalf("unstamped build = %q, want the latest fallback", got)
	}
}

func TestDeployerMirrorStillWinsOverThePin(t *testing.T) {
	// The E2E harness and the offline bundle build their own artifacts and
	// serve them locally; the pin must not take that away.
	oldTag, oldMirror := releaseTag, os.Getenv("WOOTC_DEPLOYER_MIRROR")
	t.Cleanup(func() {
		releaseTag = oldTag
		_ = os.Setenv("WOOTC_DEPLOYER_MIRROR", oldMirror)
	})

	releaseTag = "v9.9.9"
	for in, want := range map[string]string{
		"http://192.0.2.10:8000/pool":  "http://192.0.2.10:8000/pool/",
		"http://192.0.2.10:8000/pool/": "http://192.0.2.10:8000/pool/",
	} {
		_ = os.Setenv("WOOTC_DEPLOYER_MIRROR", in)
		if got := deployerBaseURL(); got != want {
			t.Errorf("mirror %q = %q, want %q", in, got, want)
		}
	}
}
