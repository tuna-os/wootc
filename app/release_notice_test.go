package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestReleaseNotice(t *testing.T) {
	tests := []struct{ name, current, body, want string }{
		{"alpha advances numerically", "v1.0.0-alpha.9", `[{"tag_name":"v1.0.0-alpha.10","prerelease":true}]`, "v1.0.0-alpha.10"},
		{"stable ignores prerelease", "v1.0.0", `[{"tag_name":"v2.0.0-beta.1","prerelease":true}]`, ""},
		{"beta ignores future alpha", "v1.0.0-beta.1", `[{"tag_name":"v2.0.0-alpha.1","prerelease":true}]`, ""},
		{"highest published", "v1.0.0-alpha.1", `[{"tag_name":"v9.0.0","draft":true},{"tag_name":"v1.0.0-beta.1","prerelease":true},{"tag_name":"v1.1.0"}]`, "v1.1.0"},
		{"no downgrade or equal", "v1.2.0", `[{"tag_name":"v1.1.0"},{"tag_name":"v1.2.0"}]`, ""},
		{"reject malformed tags", "v1.0.0", `[{"tag_name":"<img src=x onerror=alert(1)>"},{"tag_name":"v2.0.0/../../"}]`, ""},
		{"bad JSON", "v1.0.0", `[`, ""},
		{"inconsistent prerelease", "v1.0.0", `[{"tag_name":"v2.0.0","prerelease":true}]`, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "" {
					t.Error("request contains credentials")
				}
				w.Write([]byte(tt.body))
			}))
			defer server.Close()
			got := fetchReleaseNotice(context.Background(), server.Client(), server.URL, "tuna-os/wootc", tt.current)
			if got.Version != tt.want {
				t.Fatalf("got %+v, want %q", got, tt.want)
			}
			if got.Version != "" && !strings.HasPrefix(got.URL, "https://github.com/tuna-os/wootc/releases/tag/") {
				t.Fatal(got.URL)
			}
		})
	}
}

func TestReleaseNoticeFailureDoesNotBlock(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if got := fetchReleaseNotice(ctx, server.Client(), server.URL, "tuna-os/wootc", "v1.0.0"); got.Version != "" {
		t.Fatal(got)
	}
	for _, code := range []int{http.StatusNotFound, http.StatusForbidden, http.StatusTooManyRequests} {
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(code) }))
		if got := fetchReleaseNotice(context.Background(), s.Client(), s.URL, "tuna-os/wootc", "v1.0.0"); got.Version != "" {
			t.Fatal(got)
		}
		s.Close()
	}
}

func TestReleaseNoticeBoundedAndUnstamped(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(strings.Repeat(" ", (1<<20)+1))) }))
	defer s.Close()
	if got := fetchReleaseNotice(context.Background(), s.Client(), s.URL, "tuna-os/wootc", "v1.0.0"); got.Version != "" {
		t.Fatal(got)
	}
	old := releaseTag
	releaseTag = ""
	defer func() { releaseTag = old }()
	if got := (&App{}).GetReleaseNotice(); got.Version != "" {
		t.Fatal(got)
	}
	for _, base := range []string{"http://github.com/tuna-os/wootc/releases/", "https://evil.test/tuna-os/wootc/releases/", "https://github.com/u/p/releases/?secret=x"} {
		if releaseRepository(base) != "" {
			t.Fatal(base)
		}
	}
	if releaseRepository("https://github.com/tuna-os/wootc/releases/") != "tuna-os/wootc" {
		t.Fatal("repository discovery")
	}
}
