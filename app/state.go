package main

import (
	"os"
	"path/filepath"
	"time"
)

// ── Lifecycle state bus ───────────────────────────────────────────────────────
// C:\wootc\state.json is the single source of truth for the install
// lifecycle, shared between the GUI/headless installer (this side), the
// deployer (writes deploying/deployed/failed from deploy.sh), and the
// Phase-2 firstboot (writes healthy). See docs/gui-phase1-architecture.md
// §2.3 for the contract.

const (
	StateStaged    = "staged"    // files written, BCD not yet armed
	StateArmed     = "armed"     // one-shot bootsequence set; reboot pending
	StateDeploying = "deploying" // deployer started (written by deploy.sh)
	StateDeployed  = "deployed"  // deploy.sh finished, Phase-2 boot pending
	StateHealthy   = "healthy"   // Phase-2 userspace reached (firstboot unit)
	StateFailed    = "failed"
)

// LifecycleState is the persisted contents of state.json.
type LifecycleState struct {
	State     string `json:"state"`
	Phase     string `json:"phase,omitempty"` // failing step/phase when failed
	Error     string `json:"error,omitempty"`
	UpdatedAt string `json:"updatedAt"`
	UpdatedBy string `json:"updatedBy"`
}

func statePath() string {
	return filepath.Join(wootcDir(), "state.json")
}

// writeState persists the lifecycle state. Best-effort: state is advisory
// for UX and tests; a write failure must never abort an install step.
func writeState(state, phase, errMsg string) {
	s := LifecycleState{
		State:     state,
		Phase:     phase,
		Error:     errMsg,
		UpdatedAt: time.Now().UTC().Format(time.RFC3339),
		UpdatedBy: "wootc-installer",
	}
	_ = marshalJSONToFile(statePath(), s)
}

// readState loads state.json; ok is false when it does not exist or is
// unreadable.
func readState() (LifecycleState, bool) {
	data, err := os.ReadFile(statePath())
	if err != nil {
		return LifecycleState{}, false
	}
	var s LifecycleState
	if err := unmarshalJSON(data, &s); err != nil {
		return LifecycleState{}, false
	}
	return s, true
}
