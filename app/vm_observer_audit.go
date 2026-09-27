package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"path"
	"regexp"
	"strings"
)

// Audit fields are reports from the authenticated installer, not independent
// host syscall observations. Validate their schema/consistency; actual current
// guest root acceptance additionally requires the independent boot graph gate.
func observerAuditObject(raw json.RawMessage, keys ...string) (map[string]json.RawMessage, error) {
	object, err := decodeQMPObject(raw)
	if err != nil || len(object) != len(keys) {
		return nil, fmt.Errorf("offline installer audit schema differs")
	}
	for _, key := range keys {
		if _, ok := object[key]; !ok {
			return nil, fmt.Errorf("offline installer audit field absent")
		}
	}
	return object, nil
}
func observerAuditBool(raw json.RawMessage, value bool) bool {
	expected := "false"
	if value {
		expected = "true"
	}
	return string(bytes.TrimSpace(raw)) == expected
}
func observerAuditString(raw json.RawMessage) string {
	var value string
	_ = json.Unmarshal(raw, &value)
	return value
}
func observerAuditPath(value string) bool {
	if !strings.HasPrefix(value, "/usr/") || len(value) > 256 || path.Clean(value) != value {
		return false
	}
	for _, ch := range value {
		if ch < 33 || ch > 126 {
			return false
		}
	}
	return true
}
func verifyVMObserverAudit(raw map[string]json.RawMessage, disk string) error {
	labels, err := observerAuditObject(raw["labels"], "configuredMode", "labelsRequired", "labels")
	if err != nil {
		return err
	}
	mode := observerAuditString(labels["configuredMode"])
	if mode != "disabled" && mode != "enforcing" && mode != "permissive" {
		return fmt.Errorf("offline SELinux configuration unknown")
	}
	if !observerAuditBool(labels["labelsRequired"], mode != "disabled") {
		return fmt.Errorf("offline label policy contradicts configuration")
	}
	var contexts map[string]string
	if json.Unmarshal(labels["labels"], &contexts) != nil || contexts == nil || len(contexts) > 16 {
		return fmt.Errorf("offline label inventory unavailable")
	}
	allowed := map[string]bool{}
	for _, name := range []string{"/var", "/var/usrlocal", "/var/usrlocal/lib", "/var/usrlocal/lib/wootc", "/var/usrlocal/lib/wootc/observer", "/etc", "/etc/systemd", "/etc/systemd/system", "/etc/systemd/system/multi-user.target.wants", "/etc/systemd/system/multi-user.target.wants/wootc-observer.service", "/var/usrlocal/lib/wootc/observer/boot_probe.py", "/var/usrlocal/lib/wootc/observer/wootc_ancestry.py", "/etc/systemd/system/wootc-observer.service"} {
		allowed[name] = true
	}
	context := regexp.MustCompile(`^[A-Za-z0-9_]+:[A-Za-z0-9_]+:[A-Za-z0-9_]+:s[0-9]+(?:[:-][A-Za-z0-9_,.-]+)?$`)
	for name, value := range contexts {
		if !allowed[name] || !context.MatchString(value) {
			return fmt.Errorf("offline label outside fixed inventory")
		}
	}
	if mode == "disabled" {
		if len(contexts) != 0 {
			return fmt.Errorf("disabled policy reports labels")
		}
	} else {
		for _, name := range []string{"/var/usrlocal/lib/wootc/observer/boot_probe.py", "/var/usrlocal/lib/wootc/observer/wootc_ancestry.py", "/etc/systemd/system/wootc-observer.service", "/etc/systemd/system/multi-user.target.wants/wootc-observer.service"} {
			if contexts[name] == "" {
				return fmt.Errorf("offline required object label absent")
			}
		}
	}
	deps, err := observerAuditObject(raw["targetDependencies"], "interpreter", "stdlibRoots", "loadedDependencies", "mappedDependencies")
	if err != nil {
		return err
	}
	interpreter := observerAuditString(deps["interpreter"])
	if !observerAuditPath(interpreter) {
		return fmt.Errorf("offline interpreter namespace unavailable")
	}
	var loaded map[string]string
	if json.Unmarshal(deps["loadedDependencies"], &loaded) != nil || len(loaded) == 0 || len(loaded) > 128 {
		return fmt.Errorf("offline loaded dependencies absent")
	}
	for name, digest := range loaded {
		if !observerAuditPath(name) || !vmGuestSHA.MatchString(digest) {
			return fmt.Errorf("offline dependency namespace/hash invalid")
		}
	}
	if loaded[interpreter] == "" {
		return fmt.Errorf("offline interpreter digest absent")
	}
	for _, key := range []string{"stdlibRoots", "mappedDependencies"} {
		var values []string
		if json.Unmarshal(deps[key], &values) != nil || len(values) == 0 || len(values) > 128 {
			return fmt.Errorf("offline dependency inventory absent")
		}
		seen := map[string]bool{}
		for _, value := range values {
			if !observerAuditPath(value) || seen[value] || (key == "mappedDependencies" && loaded[value] == "") {
				return fmt.Errorf("offline dependency membership inconsistent")
			}
			seen[value] = true
		}
	}
	var selected string
	device := regexp.MustCompile(`^/dev/[A-Za-z0-9._/-]+$`)
	major := regexp.MustCompile(`^[0-9]+:[0-9]+$`)
	for _, key := range []string{"offlineAncestry", "offlineBootAncestry"} {
		ancestry, err := observerAuditObject(raw[key], "source", "majorMinor", "selectedDisk", "selectedDiskDevice", "offlineInstallationOnly")
		if err != nil {
			return err
		}
		owner := observerAuditString(ancestry["selectedDiskDevice"])
		if !device.MatchString(owner) || path.Clean(owner) != owner || !device.MatchString(observerAuditString(ancestry["source"])) || !major.MatchString(observerAuditString(ancestry["majorMinor"])) || observerAuditString(ancestry["selectedDisk"]) != disk || !observerAuditBool(ancestry["offlineInstallationOnly"], true) {
			return fmt.Errorf("offline partition identity inconsistent")
		}
		if selected != "" && selected != owner {
			return fmt.Errorf("offline root and boot report different disks")
		}
		selected = owner
	}
	persistence, err := observerAuditObject(raw["persistenceConfiguration"], "etcPersistent", "varPersistent", "configurationOnly")
	if err != nil {
		return err
	}
	for _, key := range []string{"etcPersistent", "varPersistent", "configurationOnly"} {
		if !observerAuditBool(persistence[key], true) {
			return fmt.Errorf("offline persistence configuration unknown")
		}
	}
	return nil
}
