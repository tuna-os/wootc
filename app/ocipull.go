package main

// Windows-side image pre-download (docs/branding-and-distribution.md §3).
//
// Principle: Windows does all networking; the deployer does none. A laptop's
// Wi-Fi does not exist in the deployer initramfs, so any image byte that is
// not on disk before the reboot may never arrive. This pulls the selected
// bootc image into C:\wootc\bundle\oci while the user's working Windows
// network is still around — a plain-file OCI image layout, chosen because it
// is NTFS-safe (no xattrs, no whiteouts, no storage-driver expectations —
// exactly the #196 containers-storage trap) and digest-addressed, so
// verification is inherent: every blob is streamed through sha256 and
// refused on mismatch.
//
// Deliberately implemented against the OCI distribution HTTP API directly —
// four requests and a checksum — rather than pulling in a container stack:
// the app needs "download and verify some blobs", not image storage.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	mtOCIIndex      = "application/vnd.oci.image.index.v1+json"
	mtOCIManifest   = "application/vnd.oci.image.manifest.v1+json"
	mtDockerList    = "application/vnd.docker.distribution.manifest.list.v2+json"
	mtDockerV2      = "application/vnd.docker.distribution.manifest.v2+json"
	manifestAccepts = mtOCIIndex + ", " + mtOCIManifest + ", " + mtDockerList + ", " + mtDockerV2
)

type ociDescriptor struct {
	MediaType string `json:"mediaType"`
	Digest    string `json:"digest"`
	Size      int64  `json:"size"`
	Platform  *struct {
		Architecture string `json:"architecture"`
		OS           string `json:"os"`
	} `json:"platform,omitempty"`
	Annotations map[string]string `json:"annotations,omitempty"`
}

type ociManifest struct {
	MediaType string          `json:"mediaType"`
	Config    ociDescriptor   `json:"config"`
	Layers    []ociDescriptor `json:"layers"`
	Manifests []ociDescriptor `json:"manifests"` // present when this is an index
}

// registryRef splits ghcr.io/org/name:tag (or @sha256:…) into its parts.
func registryRef(imageRef string) (host, repo, ref string, err error) {
	rest := imageRef
	if i := strings.Index(rest, "/"); i > 0 {
		host, rest = rest[:i], rest[i+1:]
	} else {
		return "", "", "", fmt.Errorf("image ref %q has no registry host", imageRef)
	}
	ref = "latest"
	if i := strings.Index(rest, "@"); i >= 0 {
		rest, ref = rest[:i], rest[i+1:]
	} else if i := strings.LastIndex(rest, ":"); i >= 0 {
		rest, ref = rest[:i], rest[i+1:]
	}
	if rest == "" || ref == "" {
		return "", "", "", fmt.Errorf("cannot parse image ref %q", imageRef)
	}
	return host, rest, ref, nil
}

// ociPuller carries one pull's registry session (anonymous bearer token).
type ociPuller struct {
	client *http.Client
	host   string
	repo   string
	token  string
}

// authorize performs the anonymous token dance the OCI distribution spec
// describes: an unauthenticated /v2/ probe answers 401 with a
// WWW-Authenticate header naming the token endpoint; a GET there returns a
// pull-scoped anonymous token. Public images need nothing more.
func (p *ociPuller) authorize(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, "GET", "https://"+p.host+"/v2/", nil)
	if err != nil {
		return err
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		return nil // open registry, no token needed
	}
	hdr := resp.Header.Get("Www-Authenticate")
	if !strings.HasPrefix(hdr, "Bearer ") {
		return nil
	}
	params := map[string]string{}
	for _, kv := range strings.Split(strings.TrimPrefix(hdr, "Bearer "), ",") {
		if k, v, ok := strings.Cut(strings.TrimSpace(kv), "="); ok {
			params[k] = strings.Trim(v, `"`)
		}
	}
	if params["realm"] == "" {
		return fmt.Errorf("registry %s: unparseable auth challenge %q", p.host, hdr)
	}
	tokURL := params["realm"] + "?service=" + params["service"] +
		"&scope=repository:" + p.repo + ":pull"
	treq, err := http.NewRequestWithContext(ctx, "GET", tokURL, nil)
	if err != nil {
		return err
	}
	tresp, err := p.client.Do(treq)
	if err != nil {
		return fmt.Errorf("registry token: %w", err)
	}
	defer tresp.Body.Close()
	if tresp.StatusCode != http.StatusOK {
		return fmt.Errorf("registry token: HTTP %d from %s", tresp.StatusCode, params["realm"])
	}
	var tok struct {
		Token       string `json:"token"`
		AccessToken string `json:"access_token"`
	}
	if err := json.NewDecoder(io.LimitReader(tresp.Body, 1<<20)).Decode(&tok); err != nil {
		return fmt.Errorf("registry token: %w", err)
	}
	p.token = tok.Token
	if p.token == "" {
		p.token = tok.AccessToken
	}
	return nil
}

func (p *ociPuller) get(ctx context.Context, path, accept string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", "https://"+p.host+"/v2/"+p.repo+"/"+path, nil)
	if err != nil {
		return nil, err
	}
	if accept != "" {
		req.Header.Set("Accept", accept)
	}
	if p.token != "" {
		// Go drops the Authorization header itself on cross-host redirects
		// (blob GETs bounce to a CDN), which is exactly right.
		req.Header.Set("Authorization", "Bearer "+p.token)
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, fmt.Errorf("GET %s: HTTP %d", path, resp.StatusCode)
	}
	return resp, nil
}

// fetchManifest returns the platform manifest's raw bytes and digest,
// resolving one level of multi-arch index to linux/amd64.
func (p *ociPuller) fetchManifest(ctx context.Context, ref string) ([]byte, string, error) {
	resp, err := p.get(ctx, "manifests/"+ref, manifestAccepts)
	if err != nil {
		return nil, "", err
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	resp.Body.Close()
	if err != nil {
		return nil, "", err
	}
	sum := sha256.Sum256(raw)
	digest := "sha256:" + hex.EncodeToString(sum[:])
	// A ref pinned by digest must hash to that digest — this is the
	// fail-closed heart of the whole download.
	if strings.HasPrefix(ref, "sha256:") && ref != digest {
		return nil, "", fmt.Errorf("manifest %s hashed to %s — refusing tampered content", ref, digest)
	}
	var m ociManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, "", fmt.Errorf("parse manifest: %w", err)
	}
	if m.MediaType == mtOCIIndex || m.MediaType == mtDockerList || len(m.Manifests) > 0 {
		for _, d := range m.Manifests {
			if d.Platform != nil && d.Platform.OS == "linux" && d.Platform.Architecture == "amd64" {
				return p.fetchManifest(ctx, d.Digest)
			}
		}
		return nil, "", fmt.Errorf("no linux/amd64 manifest in index %s", digest)
	}
	return raw, digest, nil
}

// writeBlob streams one blob into blobs/sha256/<hex>, verifying the digest as
// it writes. An existing file of the right size is trusted (its name IS its
// checksum — an earlier verified download) so an interrupted pull resumes
// instead of starting over.
func (p *ociPuller) writeBlob(ctx context.Context, blobDir string, d ociDescriptor, tick func(delta int64)) error {
	hexPart, ok := strings.CutPrefix(d.Digest, "sha256:")
	if !ok {
		return fmt.Errorf("unsupported digest %q", d.Digest)
	}
	final := filepath.Join(blobDir, hexPart)
	if st, err := os.Stat(final); err == nil && st.Size() == d.Size {
		tick(d.Size)
		return nil
	}
	resp, err := p.get(ctx, "blobs/"+d.Digest, "")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	tmp := final + ".part"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	h := sha256.New()
	buf := make([]byte, 1<<20)
	var written int64
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			h.Write(buf[:n])
			if _, werr := f.Write(buf[:n]); werr != nil {
				f.Close()
				os.Remove(tmp)
				return werr
			}
			written += int64(n)
			tick(int64(n))
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			f.Close()
			os.Remove(tmp)
			return rerr
		}
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if got := "sha256:" + hex.EncodeToString(h.Sum(nil)); got != d.Digest {
		os.Remove(tmp)
		return fmt.Errorf("blob %s downloaded as %s — refusing corrupted or tampered content", d.Digest, got)
	}
	if d.Size >= 0 && written != d.Size {
		os.Remove(tmp)
		return fmt.Errorf("blob %s: got %d bytes, manifest says %d", d.Digest, written, d.Size)
	}
	return os.Rename(tmp, final)
}

// discardIncompleteBlobs removes the *.part files that an interrupted pull
// left behind (#288). writeBlob only renames a .part to its final name after
// the digest check passes, so a .part is never trusted: it is either
// re-created from byte zero by the retry, or it belongs to a layer the retry
// no longer needs (the user picked a different image) and would otherwise
// hold gigabytes of C: for good. Completed blobs are left alone; their name
// is their verified checksum, so the retry reuses them.
func discardIncompleteBlobs(blobDir string) error {
	entries, err := os.ReadDir(blobDir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".part") {
			continue
		}
		if err := os.Remove(filepath.Join(blobDir, e.Name())); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("discard incomplete blob %s: %w", e.Name(), err)
		}
	}
	return nil
}

// pullImageToOCILayout downloads imageRef into an OCI image layout at destDir.
// Returns the platform manifest digest and the total layout size. progress is
// called with cumulative verified bytes against the expected total.
func pullImageToOCILayout(ctx context.Context, imageRef, destDir string, progress func(done, total int64)) (string, int64, error) {
	host, repo, ref, err := registryRef(imageRef)
	if err != nil {
		return "", 0, err
	}
	p := &ociPuller{client: &http.Client{Timeout: 0}, host: host, repo: repo}
	if err := p.authorize(ctx); err != nil {
		return "", 0, err
	}
	raw, digest, err := p.fetchManifest(ctx, ref)
	if err != nil {
		return "", 0, err
	}
	var m ociManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return "", 0, err
	}
	blobDir := filepath.Join(destDir, "blobs", "sha256")
	if err := os.MkdirAll(blobDir, 0o755); err != nil {
		return "", 0, err
	}
	if err := discardIncompleteBlobs(blobDir); err != nil {
		return "", 0, err
	}
	var total int64 = m.Config.Size
	for _, l := range m.Layers {
		total += l.Size
	}
	var done int64
	tick := func(delta int64) {
		done += delta
		if progress != nil {
			progress(done, total)
		}
	}
	if err := p.writeBlob(ctx, blobDir, m.Config, tick); err != nil {
		return "", 0, err
	}
	for _, l := range m.Layers {
		if err := ctx.Err(); err != nil {
			return "", 0, err
		}
		if err := p.writeBlob(ctx, blobDir, l, tick); err != nil {
			return "", 0, err
		}
	}
	// The manifest itself is a blob too, then the layout metadata that makes
	// this a valid `oci:` transport source for podman and fisherman.
	manifestPath := filepath.Join(blobDir, strings.TrimPrefix(digest, "sha256:"))
	if err := os.WriteFile(manifestPath, raw, 0o644); err != nil {
		return "", 0, err
	}
	mt := m.MediaType
	if mt == "" {
		mt = mtOCIManifest
	}
	index := map[string]any{
		"schemaVersion": 2,
		"manifests": []map[string]any{{
			"mediaType": mt,
			"digest":    digest,
			"size":      len(raw),
			"annotations": map[string]string{
				"org.opencontainers.image.ref.name": imageRef,
			},
		}},
	}
	idx, err := json.Marshal(index)
	if err != nil {
		return "", 0, err
	}
	if err := os.WriteFile(filepath.Join(destDir, "index.json"), idx, 0o644); err != nil {
		return "", 0, err
	}
	if err := os.WriteFile(filepath.Join(destDir, "oci-layout"),
		[]byte(`{"imageLayoutVersion":"1.0.0"}`), 0o644); err != nil {
		return "", 0, err
	}
	return digest, total, nil
}

// stageImageBundle is the "Downloading your Linux system" pipeline step: pull
// cfg's image into C:\wootc\bundle\oci and record bundle.json so the deployer
// finds and verifies it. A bundle already staged for this exact ref is reused
// (its blob names are its checksums), so retries and reinstalls skip the
// gigabytes.
func stageImageBundle(ctx context.Context, imageRef string, progress func(done, total int64)) error {
	dir := bundleDir()
	ociDir := filepath.Join(dir, "oci")
	if b := readBundleInfo(); b != nil && b.Image == imageRef {
		if _, err := os.Stat(filepath.Join(ociDir, "index.json")); err == nil {
			return nil
		}
	}
	digest, size, err := pullImageToOCILayout(ctx, imageRef, ociDir, progress)
	if err != nil {
		return fmt.Errorf("downloading %s for offline install: %w — check the internet connection and try again", imageRef, err)
	}
	info := BundleInfo{
		Image: imageRef, Digest: digest, StoreBytes: size,
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
		Source:    "predownload",
	}
	data, err := json.MarshalIndent(info, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "bundle.json"), data, 0o644)
}
