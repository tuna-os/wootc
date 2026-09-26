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

func TestRuntimeMirrorCannotRedirectBootArtifacts(t *testing.T) {
	oldTag := releaseTag
	t.Cleanup(func() { releaseTag = oldTag })
	releaseTag = "v9.9.9"
	for _, mirror := range []string{"http://192.0.2.10/pool", "https://attacker.invalid/pool"} {
		t.Setenv("WOOTC_DEPLOYER_MIRROR", mirror)
		t.Setenv("WOOTC_MANIFEST_PUBKEY", "attacker-key")
		if got := deployerBaseURL(); got != "https://github.com/tuna-os/wootc/releases/download/v9.9.9/" {
			t.Fatalf("runtime environment redirected artifacts to %q", got)
		}
	}
}

func TestDistroArtifactOriginKeepsReleasePin(t *testing.T) {
	oldBase, oldTag := releasesBaseURL, releaseTag
	t.Cleanup(func() { releasesBaseURL, releaseTag = oldBase, oldTag })
	t.Setenv("WOOTC_DEPLOYER_MIRROR", "")
	releasesBaseURL, releaseTag = "https://github.com/acme/installer/releases/", "v1.2.3"
	if got := deployerBaseURL(); got != "https://github.com/acme/installer/releases/download/v1.2.3/" {
		t.Fatalf("distro artifact origin lost pin: %s", got)
	}
}
