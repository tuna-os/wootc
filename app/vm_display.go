package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// This internal surface never exports raw QMP or guest execution. Display
// control does not prove Linux, session, editor, or desktop semantics.
type vmDisplayRequest struct {
	RunID, InstallID, DiskID, SessionID, DirectiveID string
	Action                                           string
	Keys                                             []vmDisplayKey
}
type vmDisplayKey struct {
	Code string
	Down bool
}
type vmDisplayObservation struct {
	RunID, InstallID, DiskID, SessionID, DirectiveID string
	Action                                           string
	Running                                          bool
	Mice                                             []vmDisplayMouse
	CapturePath, CaptureSHA256                       string
	Width, Height                                    int
	DesktopQualified                                 bool
}
type vmDisplayMouse struct {
	Name     string `json:"name"`
	Index    int    `json:"index"`
	Current  bool   `json:"current"`
	Absolute bool   `json:"absolute"`
}

func freshVMSessionID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}
func (s *vmSession) acquireOperation(ctx context.Context) error {
	select {
	case s.operationGate <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (s *vmSession) releaseOperation() { <-s.operationGate }
func (s *vmSession) displayIdentity(req vmDisplayRequest) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	select {
	case <-s.done:
		return fmt.Errorf("VM session exited")
	default:
	}
	if s.state.Phase != vmRunning || s.sessionID == "" || req.SessionID != s.sessionID || req.RunID == "" || req.RunID != s.state.RunID || req.InstallID == "" || req.InstallID != s.state.InstallID || req.DiskID == "" || req.DiskID != s.state.DiskID {
		return fmt.Errorf("display request does not match active VM identity")
	}
	return nil
}
func validDisplayDirective(id string) bool {
	b, err := hex.DecodeString(id)
	return err == nil && len(b) == 16 && hex.EncodeToString(b) == id
}
func strictQMPDecode(raw json.RawMessage, value any) error {
	d := json.NewDecoder(strings.NewReader(string(raw)))
	d.DisallowUnknownFields()
	return d.Decode(value)
}
func (q *qmpClient) displayStatus(ctx context.Context) (bool, error) {
	raw, err := q.request(ctx, "query-status", nil)
	if err != nil {
		return false, err
	}
	fields, shapeErr := decodeQMPObject(raw)
	if shapeErr != nil || len(fields) != 3 || fields["running"] == nil || fields["singlestep"] == nil || fields["status"] == nil {
		return false, fmt.Errorf("invalid status field shape")
	}
	var r struct {
		Running    *bool  `json:"running"`
		SingleStep *bool  `json:"singlestep"`
		Status     string `json:"status"`
	}
	if err = strictQMPDecode(raw, &r); err != nil || r.Running == nil || r.SingleStep == nil || !*r.Running || r.Status != "running" {
		return false, fmt.Errorf("VM is not positively observed running")
	}
	return true, nil
}
func (q *qmpClient) displayMice(ctx context.Context) ([]vmDisplayMouse, error) {
	raw, err := q.request(ctx, "query-mice", nil)
	if err != nil {
		return nil, err
	}
	var rows []json.RawMessage
	if err := json.Unmarshal(raw, &rows); err != nil {
		return nil, err
	}
	for _, row := range rows {
		fields, err := decodeQMPObject(row)
		if err != nil || len(fields) != 4 || fields["name"] == nil || fields["index"] == nil || fields["current"] == nil || fields["absolute"] == nil {
			return nil, fmt.Errorf("invalid mouse field shape")
		}
	}
	var records []struct {
		Name     *string `json:"name"`
		Index    *int    `json:"index"`
		Current  *bool   `json:"current"`
		Absolute *bool   `json:"absolute"`
	}
	if err = strictQMPDecode(raw, &records); err != nil || len(records) == 0 || len(records) > 16 {
		return nil, fmt.Errorf("invalid mouse inventory")
	}
	seen := map[int]bool{}
	current := 0
	var out []vmDisplayMouse
	for _, r := range records {
		if r.Name == nil || *r.Name == "" || r.Index == nil || *r.Index < 0 || *r.Index > 32 || seen[*r.Index] || r.Current == nil || r.Absolute == nil {
			return nil, fmt.Errorf("invalid mouse")
		}
		seen[*r.Index] = true
		if *r.Current {
			current++
		}
		out = append(out, vmDisplayMouse{*r.Name, *r.Index, *r.Current, *r.Absolute})
	}
	if current != 1 {
		return nil, fmt.Errorf("ambiguous active mouse")
	}
	return out, nil
}
func displayKeyEvents(keys []vmDisplayKey) ([]any, error) {
	if len(keys) == 0 || len(keys) > 64 {
		return nil, fmt.Errorf("invalid key batch size")
	}
	allowed := map[string]bool{}
	for _, k := range strings.Fields("a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9 spc ret tab esc backspace delete left right up down home end pgup pgdn shift ctrl alt dot comma minus equal slash") {
		allowed[k] = true
	}
	pressed := map[string]bool{}
	events := make([]any, 0, len(keys))
	for _, key := range keys {
		if !allowed[key.Code] || key.Down == pressed[key.Code] {
			return nil, fmt.Errorf("invalid or unbalanced key event")
		}
		pressed[key.Code] = key.Down
		events = append(events, map[string]any{"type": "key", "data": map[string]any{"down": key.Down, "key": map[string]string{"type": "qcode", "data": key.Code}}})
	}
	for _, down := range pressed {
		if down {
			return nil, fmt.Errorf("key batch leaves a key pressed")
		}
	}
	return events, nil
}
func (s *vmSession) observeDisplay(ctx context.Context, req vmDisplayRequest) (vmDisplayObservation, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	var out vmDisplayObservation
	if !validDisplayDirective(req.DirectiveID) {
		return out, fmt.Errorf("invalid display directive identity")
	}
	switch req.Action {
	case "status", "mice", "keys", "capture":
	default:
		return out, fmt.Errorf("unsupported display action")
	}
	if req.Action != "keys" && len(req.Keys) != 0 {
		return out, fmt.Errorf("unexpected keys")
	}
	var events []any
	var err error
	if req.Action == "keys" {
		if events, err = displayKeyEvents(req.Keys); err != nil {
			return out, err
		}
	}
	if err = s.acquireOperation(ctx); err != nil {
		return out, err
	}
	defer s.releaseOperation()
	if err = s.displayIdentity(req); err != nil {
		return out, err
	}
	if s.displayDirectives[req.DirectiveID] {
		return out, fmt.Errorf("display directive replay")
	}
	if len(s.displayDirectives) >= 4096 {
		return out, fmt.Errorf("display directive limit")
	}
	s.displayDirectives[req.DirectiveID] = true
	out = vmDisplayObservation{RunID: req.RunID, InstallID: req.InstallID, DiskID: req.DiskID, SessionID: req.SessionID, DirectiveID: req.DirectiveID, Action: req.Action}
	if out.Running, err = s.qmp.displayStatus(ctx); err != nil {
		return vmDisplayObservation{}, err
	}
	switch req.Action {
	case "mice":
		out.Mice, err = s.qmp.displayMice(ctx)
	case "keys":
		var raw json.RawMessage
		raw, err = s.qmp.request(ctx, "input-send-event", map[string]any{"events": events})
		if err == nil {
			var ack map[string]json.RawMessage
			ack, err = decodeQMPObject(raw)
			if err == nil && len(ack) != 0 {
				err = fmt.Errorf("invalid key acknowledgment")
			}
		}
	case "capture":
		out.CapturePath, out.CaptureSHA256, out.Width, out.Height, err = s.captureDisplay(ctx)
	}
	if err != nil {
		return vmDisplayObservation{}, err
	}
	if err = ctx.Err(); err != nil {
		return vmDisplayObservation{}, err
	}
	if err = s.displayIdentity(req); err != nil {
		return vmDisplayObservation{}, err
	}
	return out, nil
}
func (s *vmSession) captureDisplay(ctx context.Context) (string, string, int, int, error) {
	root := filepath.Dir(s.statePath)
	resolved, resolveErr := filepath.EvalSymlinks(root)
	absolute, absErr := filepath.Abs(root)
	if resolveErr != nil || absErr != nil || filepath.Clean(resolved) != filepath.Clean(absolute) {
		return "", "", 0, 0, fmt.Errorf("capture parent must be canonical")
	}
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return "", "", 0, 0, fmt.Errorf("invalid capture parent")
	}
	dir, err := os.MkdirTemp(root, ".capture-"+s.sessionID+"-")
	if err != nil {
		return "", "", 0, 0, err
	}
	success := false
	defer func() {
		if !success {
			_ = os.RemoveAll(dir)
		}
	}()
	path := filepath.Join(dir, "frame.ppm")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return "", "", 0, 0, err
	}
	if err = f.Close(); err != nil {
		return "", "", 0, 0, err
	}
	raw, err := s.qmp.request(ctx, "screendump", map[string]string{"filename": path})
	if err != nil {
		return "", "", 0, 0, err
	}
	ack, err := decodeQMPObject(raw)
	if err != nil || len(ack) != 0 {
		return "", "", 0, 0, fmt.Errorf("invalid screendump acknowledgment")
	}
	info, err = os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > 64<<20 {
		return "", "", 0, 0, fmt.Errorf("invalid capture file")
	}
	f, err = os.Open(path)
	if err != nil {
		return "", "", 0, 0, err
	}
	defer f.Close()
	h := sha256.New()
	r := bufio.NewReader(io.TeeReader(io.LimitReader(f, 64<<20), h))
	magic, e1 := r.ReadString('\n')
	dimensions, e2 := r.ReadString('\n')
	depth, e3 := r.ReadString('\n')
	parts := strings.Fields(dimensions)
	if len(magic) > 16 || len(dimensions) > 64 || len(depth) > 16 || e1 != nil || e2 != nil || e3 != nil || magic != "P6\n" || depth != "255\n" || len(parts) != 2 {
		return "", "", 0, 0, fmt.Errorf("invalid PPM header")
	}
	width, e1 := strconv.Atoi(parts[0])
	height, e2 := strconv.Atoi(parts[1])
	if e1 != nil || e2 != nil || width < 1 || height < 1 || width > 4096 || height > 4096 {
		return "", "", 0, 0, fmt.Errorf("capture dimensions out of bounds")
	}
	n, err := io.Copy(io.Discard, r)
	if err != nil || n != int64(width)*int64(height)*3 {
		return "", "", 0, 0, fmt.Errorf("capture pixel count mismatch")
	}
	if err = ctx.Err(); err != nil {
		return "", "", 0, 0, err
	}
	success = true
	return path, hex.EncodeToString(h.Sum(nil)), width, height, nil
}

// The future test-only RPC route must call this engine-owned path. It receives
// no pipe, socket, guest command, QMP command, or caller-selected capture path.
func (a *App) observeVMDisplay(ctx context.Context, req vmDisplayRequest) (vmDisplayObservation, error) {
	a.vmMu.Lock()
	session := a.vmSession
	a.vmMu.Unlock()
	if session == nil {
		return vmDisplayObservation{}, fmt.Errorf("no VM session owned by this engine")
	}
	out, err := session.observeDisplay(ctx, req)
	if err != nil {
		return vmDisplayObservation{}, err
	}
	a.vmMu.Lock()
	same := a.vmSession == session
	a.vmMu.Unlock()
	if !same {
		return vmDisplayObservation{}, fmt.Errorf("engine VM session changed")
	}
	return out, nil
}
