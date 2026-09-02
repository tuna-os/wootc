package main

import (
	"os"
	"strings"
)

// ── Where the boot artifacts come from ────────────────────────────────────
// Cross-platform on purpose: the rule is pure string logic, and the CI test
// tier runs on Linux. A Windows-only helper here would be a rule nothing
// checks until a release goes out.

const releasesBaseURL = "https://github.com/tuna-os/wootc/releases/"

// deployerBaseURL returns where boot artifacts + SHA256SUMS are fetched from.
//
// PINNED to the release this exe was cut from (#335), not `latest`. The two
// halves ship together and are tested together: an exe from
// v0.1.0-alpha.1 pulling whatever `latest` points at today runs a deployer
// kernel, initramfs and signed shim it has never been run with, and the
// SHA256SUMS check cannot catch that — the manifest is fetched from the same
// moved release, so mismatched-but-consistent artifacts verify perfectly.
// Version skew between the installer and its boot chain is now impossible.
//
// An unstamped build (a local `go build`) has no release to pin to and falls
// back to `latest`, which is the only thing a developer build can do.
//
// WOOTC_DEPLOYER_MIRROR still overrides everything for local/offline testing
// and for the E2E harness, which builds its own artifacts. The fail-closed
// SHA256SUMS verification in downloadDeployer applies unchanged against
// whatever URL is used, so none of this weakens verification — only where it
// points.
func deployerBaseURL() string {
	if v := strings.TrimSpace(os.Getenv("WOOTC_DEPLOYER_MIRROR")); v != "" {
		if !strings.HasSuffix(v, "/") {
			v += "/"
		}
		return v
	}
	if tag := strings.TrimSpace(releaseTag); tag != "" {
		return releasesBaseURL + "download/" + tag + "/"
	}
	return releasesBaseURL + "latest/download/"
}
