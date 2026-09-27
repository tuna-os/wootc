package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

type fixtureVMGuestTransport struct {
	reply func(vmGuestProbeRequest) (vmGuestProbeObservation, error)
	calls int
}

func (f *fixtureVMGuestTransport) observe(ctx context.Context, r vmGuestProbeRequest) (vmGuestProbeObservation, error) {
	f.calls++
	return f.reply(r)
}
func (f *fixtureVMGuestTransport) close() error { return nil }
func routeFixture(t *testing.T) (*vmSession, *fixtureVMGuestTransport) {
	t.Helper()
	r, _ := guestProbeFixture()
	transport := &fixtureVMGuestTransport{reply: func(req vmGuestProbeRequest) (vmGuestProbeObservation, error) {
		_, reply := guestProbeFixture()
		b, _ := json.Marshal(reply)
		var out vmGuestProbeObservation
		if err := json.Unmarshal(b, &out); err != nil {
			return out, err
		}
		out.vmGuestProbeRequest = req
		return out, nil
	}}
	state := VMState{RunID: r.RunID, InstallID: r.InstallID, DiskID: r.DiskID, Username: r.Username, ObserverServiceSHA256: r.ServiceSHA256, ObserverAncestrySHA256: r.AncestrySHA256, ObserverUnitSHA256: strings.Repeat("e", 64), Phase: vmRunning, PID: 123}
	return &vmSession{state: state, guest: transport, sessionID: r.SessionID, operationGate: make(chan struct{}, 1), done: make(chan struct{})}, transport
}
func TestVMGuestRouteFixedArgs(t *testing.T) {
	s, _ := routeFixture(t)
	args, err := vmGuestRouteArgs(s.state, s.sessionID)
	if err != nil || len(args) != 6 || args[1] != "pipe,id=wootc-observer,path=wootc.observation."+s.sessionID || args[5] != "virtserialport,id=wootc-observer-port,chardev=wootc-observer,name=org.wootc.observation.1" {
		t.Fatalf("fixed route %v %v", args, err)
	}
	if args, err = vmGuestRouteArgs(VMState{}, s.sessionID); err != nil || len(args) != 0 {
		t.Fatal("uninstalled observer route enabled")
	}
	for _, bad := range []string{"foreign/path", strings.Repeat("a", 31), strings.Repeat("g", 32)} {
		if _, err = vmGuestRouteArgs(s.state, bad); err == nil {
			t.Fatal("foreign nonce accepted")
		}
	}
	s.state.ObserverUnitSHA256 = ""
	if _, err = vmGuestRouteArgs(s.state, s.sessionID); err == nil {
		t.Fatal("partial installed identity accepted")
	}
}
func TestVMGuestRouteActualConsumer(t *testing.T) {
	s, f := routeFixture(t)
	seen := map[string]bool{}
	original := f.reply
	f.reply = func(r vmGuestProbeRequest) (vmGuestProbeObservation, error) {
		if r.RunID != s.state.RunID || r.InstallID != s.state.InstallID || r.DiskID != s.state.DiskID || r.Username != s.state.Username || r.SessionID != s.sessionID || r.ServiceSHA256 != s.state.ObserverServiceSHA256 || r.AncestrySHA256 != s.state.ObserverAncestrySHA256 || r.Action != "observe-boot-session" || seen[r.RequestID] {
			t.Fatal("request borrowed identity or replayed")
		}
		seen[r.RequestID] = true
		return original(r)
	}
	for i := 0; i < 2; i++ {
		out, err := s.observeGuest(context.Background())
		if err != nil || out.DesktopQualified || out.EditorQualified || out.BootID == "" || out.OrdinarySession["User"] != "1000" {
			t.Fatalf("current observation %v %v", out, err)
		}
	}
	if s.state.DesktopReady || f.calls != 2 {
		t.Fatal("observation changed qualification or no actual exchange")
	}
}
func TestVMGuestRouteActualConsumerRefusals(t *testing.T) {
	for _, mode := range []string{"foreign-request", "wrong-root", "ordinary-root-user", "desktop-proxy", "failed-plausible", "changed-owned-state", "exited"} {
		t.Run(mode, func(t *testing.T) {
			s, f := routeFixture(t)
			original := f.reply
			f.reply = func(req vmGuestProbeRequest) (vmGuestProbeObservation, error) {
				out, err := original(req)
				if err != nil {
					return out, err
				}
				switch mode {
				case "foreign-request":
					out.RequestID = strings.Repeat("f", 32)
				case "wrong-root":
					raw, _ := base64.StdEncoding.DecodeString(out.Root.Measurements["BLOCKS"])
					out.Root.Measurements["BLOCKS"] = base64.StdEncoding.EncodeToString([]byte(strings.ReplaceAll(string(raw), req.DiskID, "ffffffff-ffff-ffff-ffff-ffffffffffff")))
				case "ordinary-root-user":
					out.OrdinarySession["User"] = "0"
				case "desktop-proxy":
					out.DesktopQualified = true
				case "failed-plausible":
					return out, fmt.Errorf("transport failed with plausible observations")
				case "changed-owned-state":
					s.mu.Lock()
					s.state.RunID = "foreign"
					s.mu.Unlock()
				case "exited":
					close(s.done)
				}
				return out, nil
			}
			if _, err := s.observeGuest(context.Background()); err == nil {
				t.Fatal("invalid actual observation accepted")
			}
			if f.calls != 1 {
				t.Fatal("vacuous refusal")
			}
		})
	}
}
func TestVMGuestRouteBudgetsAndAbsence(t *testing.T) {
	s, f := routeFixture(t)
	s.guestRequests = 128
	if _, err := s.observeGuest(context.Background()); err == nil || f.calls != 0 {
		t.Fatal("budget did not refuse before exchange")
	}
	s.guestRequests = 0
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := s.observeGuest(ctx); err == nil || f.calls != 0 {
		t.Fatal("cancelled request performed exchange")
	}
	s.guest = nil
	if _, err := s.observeGuest(context.Background()); err == nil {
		t.Fatal("missing transport accepted")
	}
	a := &App{}
	if _, err := a.ObserveVMGuestSession(); err == nil {
		t.Fatal("absent engine-owned session accepted")
	}
}

func TestVMGuestRouteActualRPCDispatch(t *testing.T) {
	s, f := routeFixture(t)
	server := &Server{app: &App{vmSession: s}}
	result, err := server.dispatch(context.Background(), jsonrpcRequest{Method: "ObserveVMGuestSession", Params: json.RawMessage("[]")})
	if err != nil || result == nil || f.calls != 1 {
		t.Fatalf("actual read-only dispatch %v %v", result, err)
	}
	for _, raw := range []string{`{"command":"exec"}`, `["foreign-run"]`, `{"serviceSha256":"foreign"}`} {
		if _, err = server.dispatch(context.Background(), jsonrpcRequest{Method: "ObserveVMGuestSession", Params: json.RawMessage(raw)}); err == nil || err.Code != errCodeInvalidParams || f.calls != 1 {
			t.Fatal("caller parameters reached observer")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = server.dispatch(ctx, jsonrpcRequest{Method: "ObserveVMGuestSession"}); err == nil || f.calls != 1 {
		t.Fatal("request context cancellation ignored")
	}
	if s.state.DesktopReady {
		t.Fatal("dispatch changed desktop qualification")
	}
}
