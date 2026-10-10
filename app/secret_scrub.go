package main

import (
	"os"
	"path/filepath"
)

// installSecretFiles lists the credential files wootc stages under
// <drive>:\wootc\install: the BitLocker recovery password (#279) and the
// re-wrapped browser session envelopes (#281). They are removed by
// scrubbing, not only by deleting the directory, because NTFS keeps a
// deleted file's clusters readable until they are reused.
func installSecretFiles(installDir string) []string {
	files := []string{filepath.Join(installDir, "bitlocker-key.txt")}
	envelopes, _ := filepath.Glob(filepath.Join(installDir, "slurp", "session", "*.enc"))
	return append(files, envelopes...)
}

// scrubFile overwrites a regular file with zeros, flushes it to disk, and
// removes it. A missing file is not an error; a symlink or a directory is
// removed without being followed or written.
func scrubFile(path string) error {
	fi, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if fi.Mode().IsRegular() && fi.Size() > 0 {
		if f, err := os.OpenFile(path, os.O_WRONLY, 0); err == nil {
			zero := make([]byte, 64*1024)
			for left := fi.Size(); left > 0; {
				n := int64(len(zero))
				if left < n {
					n = left
				}
				if _, err := f.Write(zero[:n]); err != nil {
					break
				}
				left -= n
			}
			_ = f.Sync()
			_ = f.Close()
		}
	}
	return os.Remove(path)
}

// scrubInstallSecrets scrubs every staged credential file under installDir
// and returns the paths it could not remove.
func scrubInstallSecrets(installDir string) []string {
	var failed []string
	for _, p := range installSecretFiles(installDir) {
		if err := scrubFile(p); err != nil {
			failed = append(failed, p)
		}
	}
	return failed
}
