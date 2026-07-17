package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
)

// ── Shared helpers (both platforms) ──────────────────────────────────────────

func marshalJSON(v any) ([]byte, error) {
	return json.MarshalIndent(v, "", "  ")
}

func unmarshalJSON(data []byte, v any) error {
	return json.Unmarshal(data, v)
}

func marshalJSONToFile(path string, v any) error {
	data, err := marshalJSON(v)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o600)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

func downloadFile(ctx context.Context, url, dest string, progress func(float64)) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	f, err := os.Create(dest + ".tmp")
	if err != nil {
		return err
	}
	defer f.Close()

	total := resp.ContentLength
	var written int64
	buf := make([]byte, 32*1024)
	for {
		select {
		case <-ctx.Done():
			os.Remove(dest + ".tmp")
			return ctx.Err()
		default:
		}
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if _, we := f.Write(buf[:n]); we != nil {
				return we
			}
			written += int64(n)
			if total > 0 {
				progress(float64(written) / float64(total))
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
	}
	f.Close()
	return os.Rename(dest+".tmp", dest)
}
