package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"sync"
)

// Maintenance actions of the native Manage and Recovery screens. Each runs
// through the install-purpose session with the one-shot consent of #623: the
// engine admits a plan from its own observations, grants a single-use intent,
// and runs the plan it granted only after the same observations still hold.
const (
	nativeMaintenanceUninstall      = "uninstall"
	nativeMaintenanceRepairBoot     = "repair-boot"
	nativeMaintenanceRestoreWindows = "restore-windows-boot"
	nativeMaintenanceTryAgain       = "try-again"
	nativeMaintenanceBootLinux      = "boot-linux"
)

// NativeMaintenancePlan is what the person chose on the Manage or Recovery
// screen. The uninstall options apply to the uninstall action only.
type NativeMaintenancePlan struct {
	Action          string `json:"action"`
	DeleteRootDisk  bool   `json:"deleteRootDisk"`
	RemovePartition bool   `json:"removePartition"`
}

// NativeMaintenanceGrant names the admitted plan and the observed facts the
// confirmation discloses. The intent ID is single use, as for an install.
type NativeMaintenanceGrant struct {
	SchemaVersion   int    `json:"schemaVersion"`
	Session         string `json:"session"`
	BrandID         string `json:"brandId"`
	IntentID        string `json:"intentId"`
	Action          string `json:"action"`
	DeleteRootDisk  bool   `json:"deleteRootDisk"`
	RemovePartition bool   `json:"removePartition"`
	DiskPath        string `json:"diskPath"`
	StorageDrive    string `json:"storageDrive"`
	VolumeLabel     string `json:"volumeLabel"`
	Orphaned        bool   `json:"orphaned"`
	BootState       string `json:"bootState"`
}

type nativeMaintenanceObservation struct {
	Running bool
	Info    UninstallInfo
	Boot    BootRepairReport
	Verdict RecoveryVerdict
}

// nativeMaintenanceHost holds what one install-purpose session needs for
// maintenance. Boot observation for admission writes no evidence bundle;
// InspectBoot (the screen's boot check) does, like the legacy screen.
type nativeMaintenanceHost struct {
	session, brand string
	running        func() bool
	info           func() UninstallInfo
	boot           func() BootRepairReport
	inspect        func() BootRepairReport
	verdict        func() RecoveryVerdict
	revalidateUser func() error
	run            func(NativeMaintenancePlan) error
}

func (host *nativeMaintenanceHost) usable() bool {
	return host != nil && lowerHexLength(host.session, 32) && host.brand != "" && host.running != nil && host.info != nil &&
		host.boot != nil && host.inspect != nil && host.verdict != nil && host.revalidateUser != nil && host.run != nil
}

func (host *nativeMaintenanceHost) observe() nativeMaintenanceObservation {
	return nativeMaintenanceObservation{Running: host.running(), Info: host.info(), Boot: host.boot(), Verdict: host.verdict()}
}

// decodeNativeMaintenancePlan accepts exactly the plan fields, once each.
func decodeNativeMaintenancePlan(raw json.RawMessage) (NativeMaintenancePlan, error) {
	var plan NativeMaintenancePlan
	refused := fmt.Errorf("maintenance plan refused")
	if err := strictJSONObject(raw, 1024, map[string]bool{"action": true, "deleteRootDisk": true, "removePartition": true}, []string{"action"}); err != nil {
		return plan, refused
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&plan) != nil {
		return NativeMaintenancePlan{}, refused
	}
	switch plan.Action {
	case nativeMaintenanceUninstall:
	case nativeMaintenanceRepairBoot, nativeMaintenanceRestoreWindows, nativeMaintenanceTryAgain, nativeMaintenanceBootLinux:
		if plan.DeleteRootDisk || plan.RemovePartition {
			return NativeMaintenancePlan{}, refused
		}
	default:
		return NativeMaintenancePlan{}, refused
	}
	return plan, nil
}

// strictJSONObject accepts one JSON object of bounded size whose keys are
// allowed, unique and non-null, and which carries every required key.
func strictJSONObject(raw []byte, limit int, allowed map[string]bool, required []string) error {
	refused := fmt.Errorf("object refused")
	if len(raw) == 0 || len(raw) > limit {
		return refused
	}
	keys := json.NewDecoder(bytes.NewReader(raw))
	token, err := keys.Token()
	if err != nil || token != json.Delim('{') {
		return refused
	}
	seen := map[string]bool{}
	for keys.More() {
		token, err = keys.Token()
		key, ok := token.(string)
		if err != nil || !ok || !allowed[key] || seen[key] {
			return refused
		}
		seen[key] = true
		var value json.RawMessage
		if keys.Decode(&value) != nil || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return refused
		}
	}
	if _, err = keys.Token(); err != nil {
		return refused
	}
	if _, err = keys.Token(); err != io.EOF {
		return refused
	}
	for _, key := range required {
		if !seen[key] {
			return refused
		}
	}
	return nil
}

// admitNativeMaintenance decides from the engine's own observations whether
// a plan may be granted. It returns the facts the plan depends on; the
// confirmation runs the plan only if a fresh observation gives the same facts.
func admitNativeMaintenance(plan NativeMaintenancePlan, observed nativeMaintenanceObservation) (string, error) {
	if observed.Running {
		return "", fmt.Errorf("an installation is running; wait for it to finish or cancel it first")
	}
	info, boot := observed.Info, observed.Boot
	switch plan.Action {
	case nativeMaintenanceUninstall:
		if !info.Found && !info.Orphaned {
			return "", fmt.Errorf("no installation was found on this PC, so there is nothing to remove")
		}
		if plan.DeleteRootDisk && info.Orphaned {
			return "", fmt.Errorf("the Linux disk file is already gone, so there is no Linux data to delete")
		}
		if plan.RemovePartition && !(info.OnDedicatedVol && info.ReclaimGB > 0) {
			if info.PartitionRemovalReason != "" {
				return "", fmt.Errorf("%s", info.PartitionRemovalReason)
			}
			return "", fmt.Errorf("the storage volume was not created for this installation, so it cannot be removed")
		}
		return fmt.Sprintf("uninstall|%t|%t|%s|%s|%t|%s", info.Found, info.Orphaned, info.DiskPath, info.StorageDrive, info.OnDedicatedVol, info.VolumeLabel), nil
	case nativeMaintenanceRepairBoot:
		if !boot.CanRepairBoot {
			return "", fmt.Errorf("repair refused, nothing was changed: %s", strings.Join(boot.Refusals, "; "))
		}
	case nativeMaintenanceRestoreWindows:
		if !boot.CanRestoreWindows {
			return "", fmt.Errorf("the Windows boot cannot be restored from here, nothing was changed: %s", strings.Join(boot.Refusals, "; "))
		}
	case nativeMaintenanceTryAgain:
		if !observed.Verdict.CanTryAgain {
			return "", fmt.Errorf("there is no recorded installation attempt to try again")
		}
		return fmt.Sprintf("try-again|%s|%s", observed.Verdict.Verdict, observed.Verdict.Timestamp), nil
	case nativeMaintenanceBootLinux:
		if !info.Deployed {
			return "", fmt.Errorf("the installation has not finished on this PC, so there is nothing to start")
		}
		return fmt.Sprintf("boot-linux|%t|%s", info.Deployed, info.DiskPath), nil
	default:
		return "", fmt.Errorf("maintenance plan refused")
	}
	return fmt.Sprintf("%s|%s|%s|%s|%t|%t", plan.Action, boot.BootState, boot.Ownership, strings.Join(boot.WootcEntries, ","), boot.CanRepairBoot, boot.CanRestoreWindows), nil
}

// nativeMaintenanceAuthorization is the one-shot consent for one plan. The
// first confirmation attempt consumes it, whatever its outcome.
type nativeMaintenanceAuthorization struct {
	mu     sync.Mutex
	host   *nativeMaintenanceHost
	intent string
	plan   NativeMaintenancePlan
	facts  string
	used   bool
}

func (host *nativeMaintenanceHost) prepare(plan NativeMaintenancePlan) (*nativeMaintenanceAuthorization, NativeMaintenanceGrant, error) {
	if !host.usable() {
		return nil, NativeMaintenanceGrant{}, fmt.Errorf("native maintenance unavailable")
	}
	if err := host.revalidateUser(); err != nil {
		return nil, NativeMaintenanceGrant{}, err
	}
	observed := host.observe()
	facts, err := admitNativeMaintenance(plan, observed)
	if err != nil {
		return nil, NativeMaintenanceGrant{}, err
	}
	if err := host.revalidateUser(); err != nil {
		return nil, NativeMaintenanceGrant{}, err
	}
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, NativeMaintenanceGrant{}, fmt.Errorf("native maintenance intent unavailable")
	}
	authority := &nativeMaintenanceAuthorization{host: host, intent: hex.EncodeToString(nonce[:]), plan: plan, facts: facts}
	return authority, NativeMaintenanceGrant{
		SchemaVersion: 1, Session: host.session, BrandID: host.brand, IntentID: authority.intent,
		Action: plan.Action, DeleteRootDisk: plan.DeleteRootDisk, RemovePartition: plan.RemovePartition,
		DiskPath: observed.Info.DiskPath, StorageDrive: observed.Info.StorageDrive, VolumeLabel: observed.Info.VolumeLabel,
		Orphaned: observed.Info.Orphaned, BootState: observed.Boot.BootState,
	}, nil
}

type nativeMaintenanceConfirmation struct {
	Kind            string `json:"kind"`
	ProtocolVersion int    `json:"protocolVersion"`
	Session         string `json:"session"`
	BrandID         string `json:"brandId"`
	IntentID        string `json:"intentId"`
	Action          string `json:"action"`
}

func (authority *nativeMaintenanceAuthorization) confirm(data []byte) error {
	if authority == nil {
		return fmt.Errorf("native maintenance authority unavailable")
	}
	authority.mu.Lock()
	if authority.used {
		authority.mu.Unlock()
		return fmt.Errorf("native maintenance intent already consumed")
	}
	authority.used = true
	host, intent, plan, facts := authority.host, authority.intent, authority.plan, authority.facts
	authority.host, authority.plan, authority.facts = nil, NativeMaintenancePlan{}, ""
	authority.mu.Unlock()
	refused := fmt.Errorf("native maintenance confirmation refused")
	fields := []string{"kind", "protocolVersion", "session", "brandId", "intentId", "action"}
	allowed := map[string]bool{}
	for _, field := range fields {
		allowed[field] = true
	}
	if strictJSONObject(data, 4096, allowed, fields) != nil {
		return refused
	}
	var confirmation nativeMaintenanceConfirmation
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&confirmation) != nil {
		return refused
	}
	if !host.usable() || confirmation.Kind != "confirm-maintenance" || confirmation.ProtocolVersion != 1 || confirmation.Session != host.session ||
		confirmation.BrandID != host.brand || confirmation.IntentID != intent || !lowerHexLength(confirmation.IntentID, 32) || confirmation.Action != plan.Action {
		return fmt.Errorf("native maintenance confirmation binding refused")
	}
	if err := host.revalidateUser(); err != nil {
		return err
	}
	current, err := admitNativeMaintenance(plan, host.observe())
	if err != nil {
		return err
	}
	if current != facts {
		return fmt.Errorf("this PC changed since the plan was checked; nothing was changed")
	}
	if err := host.revalidateUser(); err != nil {
		return err
	}
	return host.run(plan)
}

// runNativeMaintenance performs an admitted plan with the same engine calls
// as the legacy screens.
func runNativeMaintenance(app *App, plan NativeMaintenancePlan) error {
	switch plan.Action {
	case nativeMaintenanceUninstall:
		return app.UninstallWith(UninstallOptions{DeleteRootDisk: plan.DeleteRootDisk, RemovePartition: plan.RemovePartition})
	case nativeMaintenanceRepairBoot:
		return app.RepairBoot()
	case nativeMaintenanceRestoreWindows:
		_, err := app.RestoreWindowsBoot()
		return err
	case nativeMaintenanceTryAgain:
		return app.TryAgain()
	case nativeMaintenanceBootLinux:
		return app.BootIntoLinux()
	}
	return fmt.Errorf("maintenance plan refused")
}
