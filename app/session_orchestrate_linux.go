//go:build linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

var sessionImportMutex sync.Mutex

func sessionTargetRoot(home, packaging string) (string, error) {
	switch packaging {
	case "flatpak":
		return filepath.Join(home, ".var", "app", "com.google.Chrome", "config", "google-chrome"), nil
	case "native":
		return filepath.Join(home, ".config", "google-chrome"), nil
	default:
		return "", errors.New("choose the installed Chrome packaging explicitly")
	}
}

func requireSessionAppStopped(root string) error {
	for _, name := range []string{"SingletonLock", "SingletonSocket", "SingletonCookie"} {
		if _, err := os.Lstat(filepath.Join(root, name)); err == nil {
			return errors.New("close Chrome completely before import (a profile singleton is present)")
		} else if !os.IsNotExist(err) {
			return errors.New("cannot inspect Chrome profile lock")
		}
	}
	processes, err := os.ReadDir("/proc")
	if err != nil {
		return errors.New("cannot inspect running browsers")
	}
	for _, process := range processes {
		if !process.IsDir() || strings.IndexFunc(process.Name(), func(r rune) bool { return r < '0' || r > '9' }) != -1 {
			continue
		}
		name, err := os.ReadFile(filepath.Join("/proc", process.Name(), "comm"))
		if err != nil {
			continue
		} // Processes may exit during enumeration.
		switch strings.TrimSpace(string(name)) {
		case "chrome", "chromium", "chromium-browse", "google-chrome":
			return errors.New("close all Chrome/Chromium processes before session import")
		}
	}
	return nil
}

func readSessionImports(path string) map[string]SessionImportResult {
	results := make(map[string]SessionImportResult)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 128*1024 {
		return results
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return results
	}
	var entries []SessionImportResult
	if json.Unmarshal(data, &entries) != nil {
		return results
	}
	for _, entry := range entries {
		if supportedSessionApp(entry.App) {
			results[entry.App] = entry
		}
	}
	return results
}

func recordSessionImport(path string, result SessionImportResult) error {
	results := readSessionImports(path)
	results[result.App] = result
	entries := make([]SessionImportResult, 0, len(results))
	for _, app := range []string{"chrome", "edge", "spotify"} {
		if entry, exists := results[app]; exists {
			entries = append(entries, entry)
		}
	}
	data, err := json.Marshal(entries)
	if err != nil {
		return errors.New("cannot encode session import outcome")
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".session-import-outcome-*")
	if err != nil {
		return errors.New("cannot stage session import outcome")
	}
	defer os.Remove(f.Name())
	_, writeErr := f.Write(data)
	syncErr := f.Sync()
	closeErr := f.Close()
	if writeErr != nil || syncErr != nil || closeErr != nil {
		return errors.New("cannot persist session import outcome")
	}
	if err := os.Rename(f.Name(), path); err != nil {
		return errors.New("cannot install session import outcome")
	}
	return syncSessionDirectory(filepath.Dir(path))
}

func importSelectedSession(ctx context.Context, request SessionImportRequest) (SessionImportResult, error) {
	result := SessionImportResult{App: request.App, State: "failed", Reason: "Session was not imported. Sign in once instead."}
	secret := []byte(request.Password)
	request.Password = ""
	defer clear(secret)
	if !supportedSessionApp(request.App) {
		return result, errors.New("application is not eligible for session import")
	}
	if !request.Consent {
		return result, errors.New("explicit per-app target import consent is required")
	}
	if !sessionProfileName(request.SourceProfile) || !sessionProfileName(request.TargetProfile) {
		return result, errors.New("select Default or a numbered Chromium Profile folder")
	}
	if request.App == "spotify" {
		result.State = "relink"
		result.Reason = "Spotify session storage is not validated for this version. Sign in once; your library is in your account."
		return result, errors.New("Spotify import requires sanitized Windows/Flatpak session records and a verified safeStorage identity; no profile was changed")
	}
	if !sessionImportMutex.TryLock() {
		return result, errors.New("another session import is already running")
	}
	defer sessionImportMutex.Unlock()
	u, err := currentUser()
	if err != nil {
		return result, err
	}
	targetRoot, err := sessionTargetRoot(u.HomeDir, request.Packaging)
	if err != nil {
		return result, err
	}
	if err := safeSessionPath(targetRoot); err != nil {
		return result, errors.New("open the selected Linux Chrome installation once, close it, then retry")
	}
	stateDirectory := filepath.Join(u.HomeDir, ".config", "wootc")
	if err := os.MkdirAll(stateDirectory, 0o700); err != nil {
		return result, errors.New("cannot create private session outcome directory")
	}
	if err := safeSessionPath(stateDirectory); err != nil {
		return result, err
	}
	// Serialize other dashboard processes, not just requests in this process.
	lock, err := os.OpenFile(filepath.Join(stateDirectory, "session-import.lock"), os.O_CREATE|os.O_RDWR|unix.O_NOFOLLOW, 0o600)
	if err != nil {
		return result, errors.New("cannot acquire session import lock")
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return result, errors.New("another session importer is active")
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	ledger := filepath.Join(stateDirectory, "session-imports.json")
	fail := func(failure error) (SessionImportResult, error) {
		result.State = "failed"
		result.Verified = false
		result.CookiesWritten = 0
		result.LocalRecordsWritten = 0
		result.Reason = failure.Error() + " Sign in once instead, or retry after resolving this condition."
		if err := recordSessionImport(ledger, result); err != nil {
			return result, fmt.Errorf("%w; %v", failure, err)
		}
		return result, failure
	}
	if err := requireSessionAppStopped(targetRoot); err != nil {
		return fail(err)
	}
	store, err := openSessionEnvelopeStore(stagedSessionDirectory)
	if err != nil {
		return fail(err)
	}
	defer store.root.Close()
	key, err := store.unlock(request.App, request.Consent, secret)
	clear(secret)
	if err != nil {
		return fail(err)
	}
	defer clear(key)
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	encryptor, err := openLinuxSafeStorage(ctx, request.Backend, "chrome")
	if err != nil {
		return fail(err)
	}
	if closer, ok := encryptor.(io.Closer); ok {
		defer closer.Close()
	}
	windowsProfile, _, err := resolvedWindowsProfile(u)
	if err != nil {
		return fail(err)
	}
	relativeRoot := filepath.Join("AppData", "Local", "Google", "Chrome", "User Data")
	if request.App == "edge" {
		relativeRoot = filepath.Join("AppData", "Local", "Microsoft", "Edge", "User Data")
	}
	sourceProfile := filepath.Join(windowsProfile, relativeRoot, request.SourceProfile)
	targetProfile := filepath.Join(targetRoot, request.TargetProfile)
	if err := safeSessionPath(sourceProfile); err != nil {
		return fail(errors.New("selected Windows browser profile is missing or unsafe"))
	}
	if err := safeSessionPath(targetProfile); err != nil {
		return fail(errors.New("selected target browser profile must already be initialized"))
	}
	var replacements []*sessionReplacement
	defer func() {
		for _, replacement := range replacements {
			replacement.discard()
		}
	}()
	cookiePath := filepath.Join(sourceProfile, "Network", "Cookies")
	if _, err := os.Lstat(cookiePath); os.IsNotExist(err) {
		cookiePath = filepath.Join(sourceProfile, "Cookies")
	}
	targetCookies := filepath.Join(targetProfile, "Network", "Cookies")
	if _, err := os.Lstat(targetCookies); os.IsNotExist(err) {
		targetCookies = filepath.Join(targetProfile, "Cookies")
	}
	cookies, counts, err := prepareChromiumCookies(ctx, cookiePath, targetCookies, key, encryptor)
	if err != nil {
		return fail(err)
	}
	replacements = append(replacements, cookies)
	result.CookiesWritten, result.RecordsPreserved = counts.Written, counts.Preserved
	sourceLocal := filepath.Join(sourceProfile, "Local Storage", "leveldb")
	if _, err := os.Lstat(sourceLocal); err == nil {
		local, counts, err := prepareChromiumLocalStorage(ctx, sourceLocal, filepath.Join(targetProfile, "Local Storage", "leveldb"))
		if err != nil {
			return fail(err)
		}
		replacements = append(replacements, local)
		result.LocalRecordsWritten = counts.Written
		result.RecordsPreserved += counts.Preserved
	} else if !os.IsNotExist(err) {
		return fail(errors.New("cannot inspect source Local Storage"))
	}
	rollback := func(cause error) (SessionImportResult, error) {
		result.Backups = nil
		for i := len(replacements) - 1; i >= 0; i-- {
			if err := replacements[i].rollback(); err != nil {
				cause = errors.Join(cause, err)
			}
			if replacements[i].installed || replacements[i].retainPrepared {
				result.Backups = append(result.Backups, replacements[i].target, replacements[i].prepared)
			}
		}
		return fail(cause)
	}
	for _, replacement := range replacements {
		replacement.rollbackGuard = func() error { return requireSessionAppStopped(targetRoot) }
		if err := ctx.Err(); err != nil {
			return rollback(err)
		}
		if err := requireSessionAppStopped(targetRoot); err != nil {
			return rollback(err)
		}
		if err := replacement.install(); err != nil {
			return rollback(err)
		}
		result.Backups = append(result.Backups, replacement.prepared)
	}
	result.State = "rewritten"
	result.Reason = "Supported store records rewritten; authentication is not verified. Open Chrome and sign in if requested. Original Linux stores are retained as backups."
	// There is deliberately no automatic imported/verified transition: only a
	// real disposable-account launch+restart matrix can define that signal.
	if err := recordSessionImport(ledger, result); err != nil {
		return rollback(err)
	}
	return result, nil
}
