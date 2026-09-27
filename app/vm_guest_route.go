package main

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

type vmGuestTransport interface {
	observe(context.Context, vmGuestProbeRequest) (vmGuestProbeObservation, error)
	close() error
}

// Fixed observation-only wiring. No caller chooses a path, command or QMP verb.
func vmGuestRouteArgs(state VMState, nonce string) ([]string, error) {
	if state.ObserverServiceSHA256 == "" && state.ObserverAncestrySHA256 == "" && state.ObserverUnitSHA256 == "" {
		return nil, nil
	}
	if !vmGuestSHA.MatchString(state.ObserverUnitSHA256) {
		return nil, fmt.Errorf("installed observer unit identity unavailable")
	}
	req := vmGuestProbeRequest{SchemaVersion: 1, RunID: state.RunID, InstallID: state.InstallID, DiskID: state.DiskID, SessionID: nonce, RequestID: nonce, Username: state.Username, Action: "observe-boot-session", ServiceSHA256: state.ObserverServiceSHA256, AncestrySHA256: state.ObserverAncestrySHA256}
	if err := validateVMGuestRequest(req); err != nil {
		return nil, err
	}
	return []string{"-chardev", "pipe,id=wootc-observer,path=wootc.observation." + nonce, "-device", "virtio-serial-pci,id=wootc-observer-serial", "-device", "virtserialport,id=wootc-observer-port,chardev=wootc-observer,name=org.wootc.observation.1"}, nil
}

// VMGuestSessionObservation reports current observations only. The service and
// independent Go ancestry decoder cannot establish an editor save or desktop.
type VMGuestSessionObservation struct {
	RunID            string            `json:"runId"`
	InstallID        string            `json:"installId"`
	DiskID           string            `json:"diskId"`
	SessionID        string            `json:"sessionId"`
	RequestID        string            `json:"requestId"`
	BootID           string            `json:"bootId"`
	KernelRelease    string            `json:"kernelRelease"`
	OrdinarySession  map[string]string `json:"ordinarySession"`
	RootTarget       string            `json:"rootTarget"`
	RootMeasurements map[string]string `json:"rootMeasurements"`
	DesktopQualified bool              `json:"desktopQualified"`
	EditorQualified  bool              `json:"editorQualified"`
}

func (s *vmSession) observeGuest(ctx context.Context) (VMGuestSessionObservation, error) {
	var out VMGuestSessionObservation
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return out, err
	}
	if err := s.acquireOperation(ctx); err != nil {
		return out, err
	}
	defer s.releaseOperation()
	if err := ctx.Err(); err != nil {
		return out, err
	}
	s.mu.Lock()
	state := s.state
	transport := s.guest
	nonce := s.sessionID
	s.mu.Unlock()
	if state.Phase != vmRunning || state.PID <= 0 || transport == nil {
		return out, fmt.Errorf("owned running guest observer unavailable")
	}
	if s.guestRequests >= 128 {
		return out, fmt.Errorf("owned guest request budget exhausted")
	}
	requestID, err := freshVMSessionID()
	if err != nil {
		return out, err
	}
	req := vmGuestProbeRequest{SchemaVersion: 1, RunID: state.RunID, InstallID: state.InstallID, DiskID: state.DiskID, SessionID: nonce, RequestID: requestID, Username: state.Username, Action: "observe-boot-session", ServiceSHA256: state.ObserverServiceSHA256, AncestrySHA256: state.ObserverAncestrySHA256}
	if _, err = vmGuestRouteArgs(state, nonce); err != nil {
		return out, err
	}
	if err = validateVMGuestRequest(req); err != nil {
		return out, err
	}
	s.guestRequests++ // A failed exchange consumes its identity; never replay it.
	observed, err := transport.observe(ctx, req)
	if err != nil {
		return out, err
	}
	// Reapply the complete strict protocol and independent ancestry gate at
	// the actual engine consumer; a transport implementation is not authority.
	raw, err := json.Marshal(observed)
	if err != nil {
		return out, err
	}
	observed, err = decodeVMGuestObservation(raw, req)
	if err != nil {
		return out, err
	}
	if err = ctx.Err(); err != nil {
		return out, err
	}
	s.mu.Lock()
	current := s.state
	s.mu.Unlock()
	if current != state {
		return out, fmt.Errorf("owned VM state changed during observation")
	}
	select {
	case <-s.done:
		return out, fmt.Errorf("owned VM exited during observation")
	default:
	}
	return VMGuestSessionObservation{RunID: req.RunID, InstallID: req.InstallID, DiskID: req.DiskID, SessionID: req.SessionID, RequestID: req.RequestID, BootID: observed.BootID, KernelRelease: observed.KernelRelease, OrdinarySession: observed.OrdinarySession, RootTarget: observed.Root.Target, RootMeasurements: observed.Root.Measurements}, nil
}

func (a *App) ObserveVMGuestSession() (VMGuestSessionObservation, error) {
	a.vmMu.Lock()
	session := a.vmSession
	a.vmMu.Unlock()
	if session == nil {
		return VMGuestSessionObservation{}, fmt.Errorf("no engine-owned VM session")
	}
	ctx := a.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	out, err := session.observeGuest(ctx)
	if err != nil {
		return VMGuestSessionObservation{}, err
	}
	a.vmMu.Lock()
	same := a.vmSession == session
	a.vmMu.Unlock()
	if !same {
		return VMGuestSessionObservation{}, fmt.Errorf("engine-owned VM session changed")
	}
	return out, nil
}
