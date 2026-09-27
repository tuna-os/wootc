package main

import "strings"

// These values are stamped at build time. The process environment and distro
// runtime branding cannot redirect privileged boot inputs or replace the key.
var releasesBaseURL = "https://github.com/tuna-os/wootc/releases/"
var artifactPublicKey string

func deployerBaseURL() string {
	if tag := strings.TrimSpace(releaseTag); tag != "" {
		return releasesBaseURL + "download/" + tag + "/"
	}
	return releasesBaseURL + "latest/download/"
}
