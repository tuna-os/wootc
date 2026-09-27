package main

import (
	"context"
	"encoding/json"
	"golang.org/x/mod/semver"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// ReleaseNotice is advisory. It never selects or downloads boot artifacts.
type ReleaseNotice struct {
	Version string `json:"version"`
	URL     string `json:"url"`
}

func releaseRepository(base string) string {
	u, err := url.Parse(base)
	if err != nil || u.Scheme != "https" || u.Host != "github.com" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return ""
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) != 3 || parts[2] != "releases" {
		return ""
	}
	for _, part := range parts[:2] {
		if part == "" || part == "." || part == ".." || strings.ContainsAny(part, "\\%?# ") {
			return ""
		}
	}
	return parts[0] + "/" + parts[1]
}

func noticeChannel(version string) int {
	p := strings.TrimPrefix(semver.Prerelease(version), "-")
	if p == "" {
		return 3
	}
	switch strings.Split(p, ".")[0] {
	case "alpha":
		return 0
	case "beta":
		return 1
	case "rc":
		return 2
	}
	return -1
}

func fetchReleaseNotice(ctx context.Context, client *http.Client, endpoint, repository, current string) ReleaseNotice {
	if !semver.IsValid(current) || noticeChannel(current) < 0 || repository == "" {
		return ReleaseNotice{}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return ReleaseNotice{}
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2026-03-10")
	req.Header.Set("User-Agent", "wootc-release-notice")
	resp, err := client.Do(req)
	if err != nil {
		return ReleaseNotice{}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ReleaseNotice{}
	}
	data, err := readBounded(resp.Body, 1<<20)
	if err != nil {
		return ReleaseNotice{}
	}
	var releases []struct {
		Tag        string `json:"tag_name"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
	}
	if json.Unmarshal(data, &releases) != nil {
		return ReleaseNotice{}
	}
	newest := current
	for _, release := range releases {
		if release.Draft || !semver.IsValid(release.Tag) {
			continue
		}
		channel := noticeChannel(release.Tag)
		if channel < noticeChannel(current) || channel < 0 || (release.Prerelease && channel == 3) {
			continue
		}
		if semver.Compare(release.Tag, newest) > 0 {
			newest = release.Tag
		}
	}
	if newest == current {
		return ReleaseNotice{}
	}
	return ReleaseNotice{Version: newest, URL: "https://github.com/" + repository + "/releases/tag/" + url.PathEscape(newest)}
}

// GetReleaseNotice makes one bounded anonymous request after the UI renders.
// Unstamped development builds do not make a request or claim an update.
func (a *App) GetReleaseNotice() ReleaseNotice {
	repository := releaseRepository(releasesBaseURL)
	if repository == "" || !semver.IsValid(releaseTag) || noticeChannel(releaseTag) < 0 {
		return ReleaseNotice{}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	client := newArtifactClient()
	client.Timeout = 3 * time.Second
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	defer client.CloseIdleConnections()
	return fetchReleaseNotice(ctx, client, "https://api.github.com/repos/"+repository+"/releases?per_page=20", repository, releaseTag)
}
