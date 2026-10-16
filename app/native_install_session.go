package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"sync"
)

// nativePurposeInstall selects the install-purpose session at launch
// (--purpose install). Any other purpose value is refused.
const nativePurposeInstall = "install"

// NativeInstallGrant is what an install-purpose session returns when the
// engine accepts a plan. It names the plan the person will confirm and the
// facts the confirmation must disclose. The intent ID is single use: the first
// ConfirmNativeInstall attempt consumes it, whatever its outcome.
type NativeInstallGrant struct {
	SchemaVersion               int    `json:"schemaVersion"`
	Session                     string `json:"session"`
	BrandID                     string `json:"brandId"`
	IntentID                    string `json:"intentId"`
	ImageRef                    string `json:"imageRef"`
	StorageDrive                string `json:"storageDrive"`
	DiskSizeGB                  int    `json:"diskSizeGB"`
	Encryption                  string `json:"encryption"`
	BitLockerOn                 bool   `json:"bitLockerOn"`
	BitLockerRecoveryKeyWarning bool   `json:"bitLockerRecoveryKeyWarning"`
	FastStartupOn               bool   `json:"fastStartupOn"`
	SecureBootChainWarning      string `json:"secureBootChainWarning"`
}

// nativeInstallAuthority is the one-shot consent boundary from #606
// (nativeInstallAuthorization on Windows): it holds the immutable plan and
// the captured original user, and runs the action at most once.
type nativeInstallAuthority interface {
	intentID() string
	confirmIntent(data []byte, action func(InstallConfig) error) error
}

// nativeInstallPrepare validates a plan and returns its authority and grant.
// A refusal error carries engine text the person can act on.
type nativeInstallPrepare func(InstallConfig) (nativeInstallAuthority, NativeInstallGrant, error)

// nativeInstallSession serves one install-purpose connection. It accepts one
// plan and one confirmation. A changed plan needs a new session, so a grant
// can never outlive the plan it was made for.
type nativeInstallSession struct {
	mu        sync.Mutex
	prepare   nativeInstallPrepare
	start     func(InstallConfig) error
	reboot    func() error
	authority nativeInstallAuthority
	// maintenance serves the Manage and Recovery actions. A session holds
	// one plan of either kind: an install or one maintenance action.
	maintenance          *nativeMaintenanceHost
	maintenanceAuthority *nativeMaintenanceAuthorization
	// vm serves the VM contract. A session that used a VM grant takes no
	// install or maintenance plan; one VM grant is pending at a time.
	vm          *nativeVMHost
	vmAuthority *nativeVMAuthorization
	vmUsed      bool
	prepared    bool
	confirmed   bool
	started     bool
}

// withReboot sets the restart action. A restart is offered only after this
// session's own confirmed install finished without an error.
func (session *nativeInstallSession) withReboot(reboot func() error) *nativeInstallSession {
	session.reboot = reboot
	return session
}

// withMaintenance sets the uninstall and boot-repair actions of this session.
func (session *nativeInstallSession) withMaintenance(host *nativeMaintenanceHost) *nativeInstallSession {
	session.maintenance = host
	return session
}

// read serves the two observations the Manage and Recovery screens need
// before a plan: where the installation lives, and the boot check.
// withVM sets the VM contract of this session.
func (session *nativeInstallSession) withVM(host *nativeVMHost) *nativeInstallSession {
	session.vm = host
	return session
}

func (session *nativeInstallSession) vmStatus(params json.RawMessage) (any, *jsonrpcError) {
	if len(params) != 0 && string(params) != "null" {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "this observation accepts no parameters"}
	}
	session.mu.Lock()
	host := session.vm
	session.mu.Unlock()
	if !host.usable() {
		return nil, &jsonrpcError{Code: errCodeMethodNotFound, Message: "method unavailable in install session"}
	}
	return host.observe().status(), nil
}

func (session *nativeInstallSession) read(method string, params json.RawMessage) (any, *jsonrpcError) {
	if len(params) != 0 && string(params) != "null" {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "this observation accepts no parameters"}
	}
	session.mu.Lock()
	host := session.maintenance
	session.mu.Unlock()
	if !host.usable() {
		return nil, &jsonrpcError{Code: errCodeMethodNotFound, Message: "method unavailable in install session"}
	}
	if method == "InspectBoot" {
		return host.inspect(), nil
	}
	return host.info(), nil
}

func (session *nativeInstallSession) restart(status InstallStatus) (any, *jsonrpcError) {
	session.mu.Lock()
	started, reboot := session.started, session.reboot
	session.mu.Unlock()
	if !started || !status.Done || status.Running || status.Error != "" || reboot == nil {
		return nil, &jsonrpcError{Code: errCodeInternal, Message: "restart is available only after this session's installation finished"}
	}
	if err := reboot(); err != nil {
		return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
	}
	return nil, nil
}

func newNativeInstallSession(prepare nativeInstallPrepare, start func(InstallConfig) error) *nativeInstallSession {
	return &nativeInstallSession{prepare: prepare, start: start}
}

// decodeNativeInstallPlan accepts exactly the InstallConfig fields, once
// each. Fault injection and session-consent moves are not native options.
func decodeNativeInstallPlan(raw json.RawMessage) (InstallConfig, error) {
	var config InstallConfig
	if len(raw) == 0 || len(raw) > 16384 {
		return config, fmt.Errorf("install plan refused")
	}
	keys := json.NewDecoder(bytes.NewReader(raw))
	token, err := keys.Token()
	if err != nil || token != json.Delim('{') {
		return config, fmt.Errorf("install plan refused")
	}
	allowed := map[string]bool{"imageRef": true, "diskSizeGB": true, "username": true, "password": true, "hostname": true, "bootloader": true, "composeFs": true, "storageDrive": true, "encryption": true, "luksPassphrase": true, "windowsLook": true}
	seen := map[string]bool{}
	for keys.More() {
		token, err = keys.Token()
		key, ok := token.(string)
		if err != nil || !ok || !allowed[key] || seen[key] {
			return config, fmt.Errorf("install plan refused")
		}
		seen[key] = true
		var value json.RawMessage
		if keys.Decode(&value) != nil || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return config, fmt.Errorf("install plan refused")
		}
	}
	if _, err = keys.Token(); err != nil {
		return config, fmt.Errorf("install plan refused")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&config) != nil {
		return InstallConfig{}, fmt.Errorf("install plan refused")
	}
	var extra json.RawMessage
	if decoder.Decode(&extra) != io.EOF {
		return InstallConfig{}, fmt.Errorf("install plan refused")
	}
	if config.ImageRef == "" || config.Username == "" || config.Password == "" || config.StorageDrive == "" || config.DiskSizeGB <= 0 {
		return InstallConfig{}, fmt.Errorf("install plan is incomplete")
	}
	return config, nil
}

func (session *nativeInstallSession) dispatch(method string, params json.RawMessage) (any, *jsonrpcError) {
	switch method {
	case "PrepareNativeInstall":
		session.mu.Lock()
		defer session.mu.Unlock()
		if session.prepared || session.vmUsed {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: "this install session already holds a plan; start a new session for a changed plan"}
		}
		session.prepared = true
		plan, err := decodeNativeInstallPlan(params)
		if err != nil {
			return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: err.Error()}
		}
		if session.prepare == nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: "native install preparation unavailable"}
		}
		authority, grant, err := session.prepare(plan)
		if err != nil || authority == nil {
			message := "native install preparation refused"
			if err != nil {
				message = err.Error()
			}
			return nil, &jsonrpcError{Code: errCodeInternal, Message: message}
		}
		if grant.IntentID != authority.intentID() || !lowerHexLength(grant.IntentID, 32) {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: "native install preparation refused"}
		}
		session.authority = authority
		return grant, nil
	case "ConfirmNativeInstall":
		session.mu.Lock()
		authority, start := session.authority, session.start
		already := session.confirmed
		session.confirmed = true
		session.authority = nil
		session.mu.Unlock()
		if already || authority == nil || start == nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: "no install intent is available in this session"}
		}
		if err := authority.confirmIntent(params, start); err != nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
		}
		session.mu.Lock()
		session.started = true
		session.mu.Unlock()
		return nil, nil
	case "PrepareNativeMaintenance":
		session.mu.Lock()
		defer session.mu.Unlock()
		if session.prepared || session.vmUsed {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: "this install session already holds a plan; start a new session for a changed plan"}
		}
		session.prepared = true
		plan, err := decodeNativeMaintenancePlan(params)
		if err != nil {
			return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: err.Error()}
		}
		if !session.maintenance.usable() {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: "native maintenance unavailable"}
		}
		authority, grant, err := session.maintenance.prepare(plan)
		if err != nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
		}
		session.maintenanceAuthority = authority
		return grant, nil
	case "ConfirmNativeMaintenance":
		session.mu.Lock()
		authority := session.maintenanceAuthority
		already := session.confirmed
		session.confirmed = true
		session.maintenanceAuthority = nil
		session.mu.Unlock()
		if already || authority == nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: "no maintenance intent is available in this session"}
		}
		if err := authority.confirm(params); err != nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
		}
		return nil, nil
	case "PrepareNativeVMAction":
		session.mu.Lock()
		defer session.mu.Unlock()
		if session.prepared {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: "this install session already holds a plan; start a new session for the Linux window"}
		}
		plan, err := decodeNativeVMPlan(params)
		if err != nil {
			return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: err.Error()}
		}
		if !session.vm.usable() {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: "native VM control unavailable"}
		}
		// A new action replaces an unconfirmed one: its intent can never run.
		session.vmAuthority = nil
		session.vmUsed = true
		authority, grant, err := session.vm.grant(plan)
		if err != nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
		}
		session.vmAuthority = authority
		return grant, nil
	case "ConfirmNativeVMAction":
		session.mu.Lock()
		authority := session.vmAuthority
		session.vmAuthority = nil
		session.mu.Unlock()
		if authority == nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: "no VM intent is available in this session"}
		}
		if err := authority.confirm(params); err != nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
		}
		return nil, nil
	}
	return nil, &jsonrpcError{Code: errCodeMethodNotFound, Message: "method unavailable in install session"}
}
