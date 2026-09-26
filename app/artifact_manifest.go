package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"time"
	"wootc/internal/artifactauth"
)

// Privileged artifact transport never inherits user proxy settings and never
// follows an HTTPS-to-HTTP downgrade. Signatures remain mandatory over TLS.
func newArtifactClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	return &http.Client{Transport: transport, Timeout: 30 * time.Minute, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return fmt.Errorf("too many artifact redirects")
		}
		return validateArtifactURL(req.URL.String())
	}}
}

var artifactClient = newArtifactClient()

func validateArtifactURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Fragment != "" {
		return fmt.Errorf("boot artifact URL must be HTTPS without credentials or fragment")
	}
	return nil
}

func downloadBootArtifact(ctx context.Context, source, dest string, progress func(float64)) error {
	if err := validateArtifactURL(source); err != nil {
		return err
	}
	return downloadFileWithClient(ctx, artifactClient, source, dest, progress)
}

func readBounded(reader io.Reader, limit int64) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(reader, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("artifact metadata exceeds size limit")
	}
	return data, nil
}

func readArtifactMetadata(ctx context.Context, source string, limit int64) ([]byte, error) {
	if err := validateArtifactURL(source); err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return nil, err
	}
	resp, err := artifactClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("artifact metadata: HTTP %d", resp.StatusCode)
	}
	return readBounded(resp.Body, limit)
}

func readLocalMetadata(path string, limit int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return readBounded(f, limit)
}

func fetchArtifactChecksums(ctx context.Context, installDir string) (map[string]string, error) {
	// A present but invalid local manifest fails closed. Never replace evidence
	// of tampering with a network fallback that conceals the local failure.
	path := filepath.Join(installDir, "SHA256SUMS")
	data, err := readLocalMetadata(path, artifactauth.MaxManifestSize)
	var sig []byte
	if err == nil {
		sig, err = readLocalMetadata(path+".sig", 64)
	} else if os.IsNotExist(err) {
		data, err = readArtifactMetadata(ctx, deployerBaseURL()+"SHA256SUMS", artifactauth.MaxManifestSize)
		if err == nil {
			sig, err = readArtifactMetadata(ctx, deployerBaseURL()+"SHA256SUMS.sig", 64)
		}
	}
	if err != nil {
		return nil, fmt.Errorf("read signed boot manifest: %w", err)
	}
	return artifactauth.Verify(artifactPublicKey, data, sig)
}
