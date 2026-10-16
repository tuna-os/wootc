package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sync"
)

// The versioned VM contract of the native install-purpose session. The shell
// reads a projection of the VM state (no paths, process IDs, run IDs or
// runtime hashes) and changes VM state only through an engine grant with a
// single-use intent, as for an install (#623) or a maintenance action.
//
// The engine that starts a VM owns it: StopVM needs the session that
// launched it, and closing that session stops the VM. So one session may
// hold several VM grants in turn, one at a time, each used once. A session
// that used a VM grant takes no install or maintenance plan, and the other
// way round.
const (
	nativeVMSchemaVersion = 1

	nativeVMInstallRuntime = "install-runtime"
	nativeVMPrepare        = "prepare"
	nativeVMBoot           = "boot"
	nativeVMStop           = "stop"
	nativeVMForceStop      = "force-stop"
)

// NativeVMCapability is what the shell may know about one VM path.
type NativeVMCapability struct {
	Available     bool   `json:"available"`
	Reason        string `json:"reason"`
	Accelerator   string `json:"accelerator"`
	RuntimeNeeded bool   `json:"runtimeNeeded"`
}

// NativeVMStatus is the shell's view of the persistent VM system.
type NativeVMStatus struct {
	SchemaVersion int                `json:"schemaVersion"`
	Phase         string             `json:"phase"`
	Image         string             `json:"image"`
	Username      string             `json:"username"`
	DesktopReady  bool               `json:"desktopReady"`
	Error         string             `json:"error"`
	Launch        NativeVMCapability `json:"launch"`
	Prepare       NativeVMCapability `json:"prepare"`
}

// NativeVMPlan is one VM action. Image, username and password belong to
// prepare only.
type NativeVMPlan struct {
	Action   string `json:"action"`
	ImageRef string `json:"imageRef,omitempty"`
	Username string `json:"username,omitempty"`
	Password string `json:"password,omitempty"`
}

// NativeVMGrant names the admitted action and what the engine observed. It
// never carries the password.
type NativeVMGrant struct {
	SchemaVersion int    `json:"schemaVersion"`
	Session       string `json:"session"`
	BrandID       string `json:"brandId"`
	IntentID      string `json:"intentId"`
	Action        string `json:"action"`
	ImageRef      string `json:"imageRef"`
	Username      string `json:"username"`
	Phase         string `json:"phase"`
}

type nativeVMObservation struct {
	Installing bool
	State      VMState
	Launch     VMCapability
	Prepare    VMCapability
}

// nativeVMHost holds what one install-purpose session needs for the VM.
// prepare is read only while no VM disk exists: its check may probe the
// runtime, which is not needed for a system that is already prepared.
type nativeVMHost struct {
	session, brand string
	installing     func() bool
	state          func() VMState
	launch         func() VMCapability
	prepare        func() VMCapability
	revalidateUser func() error
	run            func(NativeVMPlan) error
}

func (host *nativeVMHost) usable() bool {
	return host != nil && lowerHexLength(host.session, 32) && host.brand != "" && host.installing != nil && host.state != nil &&
		host.launch != nil && host.prepare != nil && host.revalidateUser != nil && host.run != nil
}

func (host *nativeVMHost) observe() nativeVMObservation {
	observed := nativeVMObservation{Installing: host.installing(), State: host.state()}
	switch observed.State.Phase {
	case "absent", "":
		observed.Prepare = host.prepare()
	case vmReady, vmStopped:
		observed.Launch = host.launch()
	}
	return observed
}

func projectNativeVMCapability(capability VMCapability) NativeVMCapability {
	return NativeVMCapability{Available: capability.Available, Reason: capability.Reason, Accelerator: capability.Accelerator, RuntimeNeeded: capability.RuntimeNeeded}
}

func (observed nativeVMObservation) status() NativeVMStatus {
	phase := observed.State.Phase
	if phase == "" {
		phase = "absent"
	}
	return NativeVMStatus{
		SchemaVersion: nativeVMSchemaVersion, Phase: phase, Image: observed.State.Image, Username: observed.State.Username,
		DesktopReady: observed.State.DesktopReady, Error: observed.State.Error,
		Launch: projectNativeVMCapability(observed.Launch), Prepare: projectNativeVMCapability(observed.Prepare),
	}
}

func decodeNativeVMPlan(raw json.RawMessage) (NativeVMPlan, error) {
	var plan NativeVMPlan
	refused := fmt.Errorf("VM action refused")
	if err := strictJSONObject(raw, 4096, map[string]bool{"action": true, "imageRef": true, "username": true, "password": true}, []string{"action"}); err != nil {
		return plan, refused
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&plan) != nil {
		return NativeVMPlan{}, refused
	}
	switch plan.Action {
	case nativeVMPrepare:
		if err := validateVMInstallConfig(VMInstallConfig{ImageRef: plan.ImageRef, Username: plan.Username, Password: plan.Password}); err != nil {
			return NativeVMPlan{}, err
		}
	case nativeVMInstallRuntime, nativeVMBoot, nativeVMStop, nativeVMForceStop:
		if plan.ImageRef != "" || plan.Username != "" || plan.Password != "" {
			return NativeVMPlan{}, refused
		}
	default:
		return NativeVMPlan{}, refused
	}
	return plan, nil
}

// admitNativeVMAction decides from the engine's own observations whether an
// action may be granted, and returns the facts it depends on.
func admitNativeVMAction(plan NativeVMPlan, observed nativeVMObservation) (string, error) {
	if observed.Installing {
		return "", fmt.Errorf("an installation is running; wait for it to finish or cancel it first")
	}
	phase := observed.State.Phase
	if phase == "" {
		phase = "absent"
	}
	facts := plan.Action + "|" + phase + "|" + observed.State.Image
	switch plan.Action {
	case nativeVMInstallRuntime:
		if phase != "absent" || !observed.Prepare.RuntimeNeeded {
			return "", fmt.Errorf("the Linux window runtime is not needed now")
		}
	case nativeVMPrepare:
		if phase != "absent" {
			return "", fmt.Errorf("a Linux system is already prepared on this PC; start it or remove it first")
		}
		if !observed.Prepare.Available {
			return "", fmt.Errorf("%s", nonEmpty(observed.Prepare.Reason, "Linux in a window cannot be prepared on this PC"))
		}
		facts += "|" + plan.ImageRef + "|" + plan.Username
	case nativeVMBoot:
		if phase != vmReady && phase != vmStopped {
			return "", fmt.Errorf("the Linux system cannot start from %s; resolve that first", phase)
		}
		if !observed.Launch.Available {
			return "", fmt.Errorf("%s", nonEmpty(observed.Launch.Reason, "Linux in a window cannot start on this PC"))
		}
	case nativeVMStop:
		if phase != vmRunning && phase != vmStarting {
			return "", fmt.Errorf("no running Linux system is owned by this session")
		}
	case nativeVMForceStop:
		if phase != vmRunning && phase != vmStarting && phase != vmStopping && phase != vmPreparing {
			return "", fmt.Errorf("no active Linux system is owned by this session")
		}
	default:
		return "", fmt.Errorf("VM action refused")
	}
	return facts, nil
}

func nonEmpty(value, fallback string) string {
	if value != "" {
		return value
	}
	return fallback
}

// nativeVMAuthorization is the one-shot consent for one VM action.
type nativeVMAuthorization struct {
	mu     sync.Mutex
	host   *nativeVMHost
	intent string
	plan   NativeVMPlan
	facts  string
	used   bool
}

func (host *nativeVMHost) grant(plan NativeVMPlan) (*nativeVMAuthorization, NativeVMGrant, error) {
	if !host.usable() {
		return nil, NativeVMGrant{}, fmt.Errorf("native VM control unavailable")
	}
	if err := host.revalidateUser(); err != nil {
		return nil, NativeVMGrant{}, err
	}
	observed := host.observe()
	facts, err := admitNativeVMAction(plan, observed)
	if err != nil {
		return nil, NativeVMGrant{}, err
	}
	if err := host.revalidateUser(); err != nil {
		return nil, NativeVMGrant{}, err
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, NativeVMGrant{}, fmt.Errorf("native VM intent unavailable")
	}
	authority := &nativeVMAuthorization{host: host, intent: hex.EncodeToString(nonce[:]), plan: plan, facts: facts}
	grant := NativeVMGrant{
		SchemaVersion: nativeVMSchemaVersion, Session: host.session, BrandID: host.brand, IntentID: authority.intent,
		Action: plan.Action, ImageRef: observed.State.Image, Username: observed.State.Username, Phase: observed.status().Phase,
	}
	if plan.Action == nativeVMPrepare {
		grant.ImageRef, grant.Username = plan.ImageRef, plan.Username
	}
	return authority, grant, nil
}

type nativeVMConfirmation struct {
	Kind            string `json:"kind"`
	ProtocolVersion int    `json:"protocolVersion"`
	Session         string `json:"session"`
	BrandID         string `json:"brandId"`
	IntentID        string `json:"intentId"`
	Action          string `json:"action"`
}

// confirm consumes the intent on its first attempt, whatever the outcome,
// and runs the granted action only if the same observations still hold.
func (authority *nativeVMAuthorization) confirm(data []byte) error {
	if authority == nil {
		return fmt.Errorf("native VM authority unavailable")
	}
	authority.mu.Lock()
	if authority.used {
		authority.mu.Unlock()
		return fmt.Errorf("native VM intent already consumed")
	}
	authority.used = true
	host, intent, plan, facts := authority.host, authority.intent, authority.plan, authority.facts
	authority.host, authority.plan, authority.facts = nil, NativeVMPlan{}, ""
	authority.mu.Unlock()
	fields := []string{"kind", "protocolVersion", "session", "brandId", "intentId", "action"}
	allowed := map[string]bool{}
	for _, field := range fields {
		allowed[field] = true
	}
	if strictJSONObject(data, 4096, allowed, fields) != nil {
		return fmt.Errorf("native VM confirmation refused")
	}
	var confirmation nativeVMConfirmation
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&confirmation) != nil {
		return fmt.Errorf("native VM confirmation refused")
	}
	if !host.usable() || confirmation.Kind != "confirm-vm" || confirmation.ProtocolVersion != 1 || confirmation.Session != host.session ||
		confirmation.BrandID != host.brand || confirmation.IntentID != intent || !lowerHexLength(confirmation.IntentID, 32) || confirmation.Action != plan.Action {
		return fmt.Errorf("native VM confirmation binding refused")
	}
	if err := host.revalidateUser(); err != nil {
		return err
	}
	current, err := admitNativeVMAction(plan, host.observe())
	if err != nil {
		return err
	}
	if current != facts {
		return fmt.Errorf("the Linux system changed since this action was checked; nothing was changed")
	}
	if err := host.revalidateUser(); err != nil {
		return err
	}
	return host.run(plan)
}

// runNativeVMAction performs an admitted action with the legacy App methods.
// Preparation and runtime setup return once their worker starts; vm:progress
// reports the rest.
func runNativeVMAction(app *App, plan NativeVMPlan) error {
	switch plan.Action {
	case nativeVMInstallRuntime:
		return app.InstallVMRuntime()
	case nativeVMPrepare:
		return app.PrepareVM(VMInstallConfig{ImageRef: plan.ImageRef, Username: plan.Username, Password: plan.Password})
	case nativeVMBoot:
		return app.BootInVM()
	case nativeVMStop:
		return app.StopVM()
	case nativeVMForceStop:
		return app.ForceStopVM()
	}
	return fmt.Errorf("VM action refused")
}
