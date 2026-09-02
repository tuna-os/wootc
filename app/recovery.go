package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// ── Recovery Guard (§2, Borrowed from Libertix) ─────────────────────────────
// The recovery guard ensures that when Windows restarts after an armed install,
// wootc explains what happened, guarantees Windows remains unharmed, and provides
// actionable choices (Try again, Remove, Repair boot).
//
// Stored files under C:\wootc\install\:
//   - armed.json: BCD GUID, ESP partition GUID, staged ESP files & hashes,
//     prior power state, storage drive, image ref, timestamp, and exe hash.
//   - deployer-started.json: written by deploy.sh upon mounting NTFS.
//   - recovery-verdict.json: atomic verdict evaluated by recover --startup.

const (
	VerdictNeverBooted = "one-shot-never-booted"
	VerdictInterrupted = "interrupted"
	VerdictFailed      = "failed"
	VerdictDeployed    = "deployed"
	VerdictHealthy     = "healthy"
)

// PriorPowerState records hibernation and Fast Startup states before install.
type PriorPowerState struct {
	HibernateEnabled string `json:"hibernateEnabled,omitempty"`
	HiberbootEnabled string `json:"hiberbootEnabled,omitempty"`
}

// ArmedState is persisted at C:\wootc\install\armed.json when configureBCD runs.
type ArmedState struct {
	BcdGuid          string            `json:"bcdGuid"`
	EspPartitionGuid string            `json:"espPartitionGuid,omitempty"`
	EspFiles         []string          `json:"espFiles"`
	EspFileHashes    map[string]string `json:"espFileHashes,omitempty"`
	PriorPowerState  PriorPowerState   `json:"priorPowerState,omitempty"`
	StorageDrive     string            `json:"storageDrive"`
	ImageRef         string            `json:"imageRef"`
	Bootloader       string            `json:"bootloader,omitempty"`
	Timestamp        string            `json:"timestamp"`
	ExeHash          string            `json:"exeHash"`
}

// RecoveryVerdict is persisted at C:\wootc\install\recovery-verdict.json.
type RecoveryVerdict struct {
	Verdict     string   `json:"verdict"`
	Phase       string   `json:"phase,omitempty"`
	Title       string   `json:"title"`
	Message     string   `json:"message"`
	Details     string   `json:"details,omitempty"`
	LogTail     []string `json:"logTail,omitempty"`
	Untouched   bool     `json:"untouched"`
	CanTryAgain bool     `json:"canTryAgain"`
	CanRemove   bool     `json:"canRemove"`
	CanRepair   bool     `json:"canRepairBoot"`
	Timestamp   string   `json:"timestamp"`
}

func armedPath() string {
	return filepath.Join(wootcDir(), "install", "armed.json")
}

func verdictPath() string {
	return filepath.Join(wootcDir(), "install", "recovery-verdict.json")
}

func deployerStartedPath() string {
	return filepath.Join(wootcDir(), "install", "deployer-started.json")
}

// writeArmedJSON persists armed.json atomically.
func writeArmedJSON(armed ArmedState) error {
	path := armedPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("creating install dir: %w", err)
	}
	return marshalJSONToFile(path, armed)
}

// readArmedJSON reads and parses armed.json.
func readArmedJSON() (ArmedState, error) {
	data, err := os.ReadFile(armedPath())
	if err != nil {
		return ArmedState{}, err
	}
	var armed ArmedState
	if err := unmarshalJSON(data, &armed); err != nil {
		return ArmedState{}, fmt.Errorf("parsing armed.json: %w", err)
	}
	return armed, nil
}

// writeRecoveryVerdict persists recovery-verdict.json atomically.
func writeRecoveryVerdict(v RecoveryVerdict) error {
	path := verdictPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("creating install dir: %w", err)
	}
	return marshalJSONToFile(path, v)
}

// readRecoveryVerdict reads and parses recovery-verdict.json.
func readRecoveryVerdict() (RecoveryVerdict, error) {
	data, err := os.ReadFile(verdictPath())
	if err != nil {
		return RecoveryVerdict{}, err
	}
	var v RecoveryVerdict
	if err := unmarshalJSON(data, &v); err != nil {
		return RecoveryVerdict{}, fmt.Errorf("parsing recovery-verdict.json: %w", err)
	}
	return v, nil
}

// hashFile returns the SHA-256 hex digest of a file.
func hashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// friendlySplashMessageForPhase translates internal deployer phase words into
// calm, non-technical words matching the deployer's splash screen.
func friendlySplashMessageForPhase(phase string) (string, string) {
	switch phase {
	case "ntfs-mounted", "scratch-setup":
		return "Preparing your disk", "Setup stopped while preparing the disk workspace."
	case "network-wait":
		return "Waiting for a network connection", "Setup stopped while waiting for a network connection."
	case "bundle-ingest":
		return "Loading your downloaded system", "Setup stopped while loading the downloaded system image."
	case "registry-preflight":
		return "Connecting to the software library", "Setup stopped while connecting to the software registry."
	case "fisherman":
		return "Downloading and installing your Linux system", "Setup stopped while downloading and installing the system."
	case "verification":
		return "Checking your installation", "Setup stopped while verifying the installed system."
	case "reboot":
		return "Starting your new Linux system", "Setup stopped before restarting into the new system."
	default:
		return "Setting up Linux", "Setup could not finish this time."
	}
}

// readLastLogLines returns up to n non-empty trailing lines from deployer log files.
func readLastLogLines(logDir string, n int) []string {
	candidates := []string{
		filepath.Join(logDir, "logs", "deployer-last-journal.log"),
		filepath.Join(logDir, "logs", "deployer.log"),
		filepath.Join(logDir, "deployer.log"),
	}
	var data []byte
	var err error
	for _, c := range candidates {
		data, err = os.ReadFile(c)
		if err == nil && len(data) > 0 {
			break
		}
	}
	if len(data) == 0 {
		return nil
	}
	lines := strings.Split(string(data), "\n")
	var result []string
	for _, l := range lines {
		l = strings.TrimSpace(l)
		if l != "" {
			result = append(result, l)
		}
	}
	if len(result) > n {
		result = result[len(result)-n:]
	}
	return result
}

// EvaluateRecovery applies the Libertix-derived decision table to determine
// the recovery verdict based on armed state, marker files, and lifecycle state.
func EvaluateRecovery(armed ArmedState, startedExists bool, ls LifecycleState, logDir string) RecoveryVerdict {
	now := time.Now().UTC().Format(time.RFC3339)

	// Decision 1: armed.json present, deployer-started absent -> one-shot never booted Linux
	if !startedExists && ls.State != StateDeployed && ls.State != StateHealthy {
		return RecoveryVerdict{
			Verdict:     VerdictNeverBooted,
			Phase:       VerdictNeverBooted,
			Title:       "Windows started instead of the Linux installer",
			Message:     "Your computer restarted directly into Windows without starting the Linux installer.",
			Details:     "The one-time boot was not selected by firmware. Your Windows installation and all files remain completely safe and untouched.",
			Untouched:   true,
			CanTryAgain: true,
			CanRemove:   true,
			CanRepair:   true,
			Timestamp:   now,
		}
	}

	// Decision 2: deployer-started present, state=deploying -> died without reaching cleanup (interrupted)
	if ls.State == StateDeploying {
		return RecoveryVerdict{
			Verdict:     VerdictInterrupted,
			Phase:       StateDeploying,
			Title:       "Installation was interrupted unexpectedly",
			Message:     "The setup process was interrupted before it could finish (for example, by a power loss or unexpected restart).",
			Details:     "The deployer started but did not reach cleanup. Your Windows installation and all files remain completely safe and untouched.",
			Untouched:   true,
			CanTryAgain: true,
			CanRemove:   true,
			CanRepair:   true,
			Timestamp:   now,
		}
	}

	// Decision 3: deployer-started present, state=failed -> failed cleanly with phase
	if ls.State == StateFailed {
		title, msg := friendlySplashMessageForPhase(ls.Phase)
		logTail := readLastLogLines(logDir, 30)
		return RecoveryVerdict{
			Verdict:     VerdictFailed,
			Phase:       ls.Phase,
			Title:       title,
			Message:     msg,
			Details:     ls.Error,
			LogTail:     logTail,
			Untouched:   true,
			CanTryAgain: true,
			CanRemove:   true,
			CanRepair:   true,
			Timestamp:   now,
		}
	}

	// Decision 4: deployer-started present, state=deployed -> Phase-2 pending or booted
	if ls.State == StateDeployed {
		return RecoveryVerdict{
			Verdict:     VerdictDeployed,
			Phase:       StateDeployed,
			Title:       "Linux setup completed",
			Message:     "Phase-2 Linux system is staged and ready to boot.",
			Details:     "The installer finished successfully. Phase-2 boot is pending.",
			Untouched:   true,
			CanTryAgain: true,
			CanRemove:   true,
			CanRepair:   false,
			Timestamp:   now,
		}
	}

	// Decision 5: state=healthy -> Phase-2 userspace reached and verified
	if ls.State == StateHealthy {
		return RecoveryVerdict{
			Verdict:     VerdictHealthy,
			Phase:       StateHealthy,
			Title:       "Linux installation complete",
			Message:     "Phase-2 userspace reached and healthy.",
			Untouched:   false,
			CanTryAgain: false,
			CanRemove:   false,
			CanRepair:   false,
			Timestamp:   now,
		}
	}

	// Fallback for unrecognized combination
	return RecoveryVerdict{
		Verdict:     VerdictNeverBooted,
		Title:       "Windows started normally",
		Message:     "Your computer restarted back into Windows.",
		Untouched:   true,
		CanTryAgain: true,
		CanRemove:   true,
		CanRepair:   true,
		Timestamp:   now,
	}
}
