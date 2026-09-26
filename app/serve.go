package main

//go:generate go run ./tools/gendto

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

// ── JSON-RPC 2.0 Protocol Types ──────────────────────────────────────────────

const (
	errCodeParseError     = -32700
	errCodeInvalidRequest = -32600
	errCodeMethodNotFound = -32601
	errCodeInvalidParams  = -32602
	errCodeInternal       = -32603
)

// ProtocolMethods lists every method exposed over JSON-RPC 2.0.
// docs/winui-shell.md is the source of truth for this list.
var ProtocolMethods = []string{
	"GetSupportPolicy",
	"GetSystemInfo",
	"GetBranding",
	"GetImages",
	"GetSessionCandidates",
	"StartInstall",
	"CancelInstall",
	"GetStatus",
	"DefragDrive",
	"Reboot",
	"ExistingInstallFound",
	"GetUninstallInfo",
	"UninstallWith",
	"BootIntoLinux",
	"GetLastRun",
	"E2EDriveDirective",
	"E2EDriveReport",
	"Shutdown",
}

type jsonrpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type jsonrpcSuccessResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result"`
}

type jsonrpcErrorResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Error   jsonrpcError    `json:"error"`
}

type jsonrpcNotification struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  any    `json:"params"`
}

type jsonrpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

// synchronizedWriter guards concurrent writes to stdout so responses and
// notifications never interleave.
type synchronizedWriter struct {
	mu      sync.Mutex
	out     io.Writer
	stopped atomic.Bool
}

func (w *synchronizedWriter) WriteLine(b []byte) error {
	if w.stopped.Load() {
		return io.ErrClosedPipe
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.stopped.Load() {
		return io.ErrClosedPipe
	}
	if _, err := w.out.Write(b); err != nil {
		return err
	}
	if len(b) == 0 || b[len(b)-1] != '\n' {
		if _, err := w.out.Write([]byte("\n")); err != nil {
			return err
		}
	}
	return nil
}

// stop prevents cleanup events from waiting for an absent reader. Closing a
// pipe also releases an in-flight Write; do not take the write mutex here.
func (w *synchronizedWriter) stop() {
	if !w.stopped.Swap(true) {
		if closer, ok := w.out.(io.Closer); ok {
			_ = closer.Close()
		}
	}
}

// ── Parameter Unmarshaling ───────────────────────────────────────────────────

func unmarshalParams(raw json.RawMessage, target any) error {
	if len(raw) == 0 || string(raw) == "null" {
		return errors.New("params required")
	}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 {
		return errors.New("params required")
	}
	if trimmed[0] == '[' {
		var arr []json.RawMessage
		if err := json.Unmarshal(trimmed, &arr); err != nil {
			return err
		}
		if len(arr) == 0 {
			return errors.New("empty params array")
		}
		return json.Unmarshal(arr[0], target)
	}
	return json.Unmarshal(trimmed, target)
}

func unmarshalStringParam(raw json.RawMessage, target *string) error {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || string(trimmed) == "null" {
		*target = ""
		return nil
	}
	if trimmed[0] == '[' {
		var arr []string
		if err := json.Unmarshal(trimmed, &arr); err == nil && len(arr) > 0 {
			*target = arr[0]
			return nil
		}
	}
	if trimmed[0] == '{' {
		var obj struct {
			State  string `json:"state"`
			Report string `json:"report"`
		}
		if err := json.Unmarshal(trimmed, &obj); err == nil {
			if obj.State != "" {
				*target = obj.State
				return nil
			}
			if obj.Report != "" {
				*target = obj.Report
				return nil
			}
		}
	}
	return json.Unmarshal(trimmed, target)
}

// ── JSON-RPC 2.0 Server ─────────────────────────────────────────────────────

type Server struct {
	app      *App
	writer   *synchronizedWriter
	mu       sync.Mutex
	shutdown bool
}

func NewServer(app *App, writer *synchronizedWriter) *Server {
	return &Server{
		app:    app,
		writer: writer,
	}
}

func (s *Server) dispatch(ctx context.Context, req jsonrpcRequest) (any, *jsonrpcError) {
	switch req.Method {
	case "GetSupportPolicy":
		return s.app.GetSupportPolicy(), nil

	case "GetSystemInfo":
		return s.app.GetSystemInfo(), nil

	case "GetBranding":
		return s.app.GetBranding(), nil

	case "GetImages":
		imgs, err := s.app.GetImages()
		if err != nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
		}
		if imgs == nil {
			imgs = []Image{}
		}
		return imgs, nil

	case "GetSessionCandidates":
		candidates, err := s.app.GetSessionCandidates()
		if err != nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
		}
		if candidates == nil {
			candidates = []SessionCandidate{}
		}
		return candidates, nil

	case "StartInstall":
		var cfg InstallConfig
		if err := unmarshalParams(req.Params, &cfg); err != nil {
			return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: fmt.Sprintf("invalid StartInstall params: %v", err)}
		}
		if err := s.app.StartInstall(cfg); err != nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
		}
		return nil, nil

	case "CancelInstall":
		s.app.CancelInstall()
		return nil, nil

	case "GetStatus":
		return s.app.GetStatus(), nil

	case "DefragDrive":
		if err := s.app.DefragDrive(); err != nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
		}
		return nil, nil

	case "Reboot":
		if err := s.app.Reboot(); err != nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
		}
		return nil, nil

	case "ExistingInstallFound":
		return s.app.ExistingInstallFound(), nil

	case "GetUninstallInfo":
		return s.app.GetUninstallInfo(), nil

	case "UninstallWith":
		var opts UninstallOptions
		if err := unmarshalParams(req.Params, &opts); err != nil {
			return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: fmt.Sprintf("invalid UninstallWith params: %v", err)}
		}
		if err := s.app.UninstallWith(opts); err != nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
		}
		return nil, nil

	case "BootIntoLinux":
		if err := s.app.BootIntoLinux(); err != nil {
			return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
		}
		return nil, nil

	case "GetLastRun":
		return s.app.GetLastRun(), nil

	case "E2EDriveDirective":
		return s.app.E2EDriveDirective(), nil

	case "E2EDriveReport":
		var state string
		if err := unmarshalStringParam(req.Params, &state); err != nil {
			return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: fmt.Sprintf("invalid E2EDriveReport params: %v", err)}
		}
		s.app.E2EDriveReport(state)
		return nil, nil

	case "Shutdown":
		s.mu.Lock()
		s.shutdown = true
		s.mu.Unlock()
		return nil, nil

	default:
		return nil, &jsonrpcError{Code: errCodeMethodNotFound, Message: fmt.Sprintf("method %q not found", req.Method)}
	}
}

// Serve reads JSON-RPC 2.0 requests from in, dispatches them to app, and writes
// responses and notifications to out. On shutdown it closes out when out is
// an io.Closer, so a disconnected client cannot block installation cleanup.
func Serve(ctx context.Context, app *App, in io.Reader, out io.Writer) error {
	syncWriter := &synchronizedWriter{out: out}
	emitter := newStdioEmitter(syncWriter)
	app.SetEmitter(emitter)

	srv := NewServer(app, syncWriter)

	scanner := bufio.NewScanner(in)
	buf := make([]byte, 1024*1024)
	scanner.Buffer(buf, 10*1024*1024)

	defer func() {
		// Close the transport before waiting: a worker may be emitting progress
		// to a shell that has already gone away.
		syncWriter.stop()
		app.stopInstall(30*time.Second, func() {
			fmt.Fprintln(os.Stderr, "serve: installation is still stopping; waiting for disk/boot cleanup. Do not reboot.")
		})
	}()

	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}

		var req jsonrpcRequest
		if err := json.Unmarshal(line, &req); err != nil {
			errResp := jsonrpcErrorResponse{
				JSONRPC: "2.0",
				ID:      json.RawMessage("null"),
				Error: jsonrpcError{
					Code:    errCodeParseError,
					Message: fmt.Sprintf("parse error: %v", err),
				},
			}
			data, _ := json.Marshal(errResp)
			_ = syncWriter.WriteLine(data)
			continue
		}

		if req.JSONRPC != "2.0" || req.Method == "" {
			id := req.ID
			if len(id) == 0 {
				id = json.RawMessage("null")
			}
			errResp := jsonrpcErrorResponse{
				JSONRPC: "2.0",
				ID:      id,
				Error: jsonrpcError{
					Code:    errCodeInvalidRequest,
					Message: "invalid JSON-RPC 2.0 request",
				},
			}
			data, _ := json.Marshal(errResp)
			_ = syncWriter.WriteLine(data)
			continue
		}

		id := req.ID
		if len(id) == 0 {
			id = json.RawMessage("null")
		}

		res, rpcErr := srv.dispatch(ctx, req)
		if rpcErr != nil {
			errResp := jsonrpcErrorResponse{
				JSONRPC: "2.0",
				ID:      id,
				Error:   *rpcErr,
			}
			data, _ := json.Marshal(errResp)
			_ = syncWriter.WriteLine(data)
		} else {
			succResp := jsonrpcSuccessResponse{
				JSONRPC: "2.0",
				ID:      id,
				Result:  res,
			}
			data, _ := json.Marshal(succResp)
			_ = syncWriter.WriteLine(data)
		}

		srv.mu.Lock()
		shouldStop := srv.shutdown
		srv.mu.Unlock()
		if shouldStop {
			break
		}
	}

	return scanner.Err()
}

// runServe initializes the serve environment and runs the JSON-RPC adapter over stdio.
func runServe() int {
	initServeLogging()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	app := NewApp()
	app.startup(ctx)

	if err := Serve(ctx, app, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "serve: %v\n", err)
		return 1
	}
	return 0
}

func initServeLogging() {
	logDir := filepath.Join(wootcDir(), "logs")
	_ = os.MkdirAll(logDir, 0o755)
}
