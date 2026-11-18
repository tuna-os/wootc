package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sync"
	"testing"
	"time"
)

// ── JSON-RPC Round-Trip Pipe Tests ──────────────────────────────────────────

type pipeHarness struct {
	clientIn  *io.PipeReader
	serverOut *io.PipeWriter
	serverIn  *io.PipeReader
	clientOut *io.PipeWriter
	scanner   *bufio.Scanner
	app       *App
	cancel    context.CancelFunc
	serveErr  chan error
	mu        sync.Mutex
}

func newPipeHarness(t *testing.T) *pipeHarness {
	t.Helper()
	clientIn, serverOut := io.Pipe()
	serverIn, clientOut := io.Pipe()

	ctx, cancel := context.WithCancel(context.Background())
	app := &App{ctx: ctx}

	h := &pipeHarness{
		clientIn:  clientIn,
		serverOut: serverOut,
		serverIn:  serverIn,
		clientOut: clientOut,
		scanner:   bufio.NewScanner(clientIn),
		app:       app,
		cancel:    cancel,
		serveErr:  make(chan error, 1),
	}

	go func() {
		err := Serve(ctx, app, serverIn, serverOut)
		h.serveErr <- err
		_ = serverOut.Close()
	}()

	return h
}

func (h *pipeHarness) Close() {
	h.cancel()
	_ = h.clientOut.Close()
	_ = h.serverIn.Close()
	_ = h.clientIn.Close()
}

func (h *pipeHarness) call(t *testing.T, method string, params any, id any) (json.RawMessage, *jsonrpcError) {
	t.Helper()
	h.mu.Lock()
	defer h.mu.Unlock()

	reqMap := map[string]any{
		"jsonrpc": "2.0",
		"method":  method,
	}
	if id != nil {
		reqMap["id"] = id
	}
	if params != nil {
		reqMap["params"] = params
	}

	reqBytes, err := json.Marshal(reqMap)
	if err != nil {
		t.Fatalf("failed to marshal request: %v", err)
	}

	if _, err := fmt.Fprintf(h.clientOut, "%s\n", reqBytes); err != nil {
		t.Fatalf("failed to write request: %v", err)
	}

	if !h.scanner.Scan() {
		t.Fatalf("no response line received: %v", h.scanner.Err())
	}

	line := h.scanner.Bytes()
	var raw struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Result  json.RawMessage `json:"result"`
		Error   *jsonrpcError   `json:"error"`
	}
	if err := json.Unmarshal(line, &raw); err != nil {
		t.Fatalf("failed to unmarshal response %q: %v", string(line), err)
	}

	if raw.JSONRPC != "2.0" {
		t.Errorf("response jsonrpc = %q, want 2.0", raw.JSONRPC)
	}

	return raw.Result, raw.Error
}

func TestNotificationsProgressAndVM(t *testing.T) {
	clientIn, serverOut := io.Pipe()
	serverIn, clientOut := io.Pipe()
	defer clientOut.Close()
	defer serverIn.Close()
	defer clientIn.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	app := &App{ctx: ctx}

	started := make(chan struct{})
	go func() {
		close(started)
		_ = Serve(ctx, app, serverIn, serverOut)
		_ = serverOut.Close()
	}()

	<-started
	time.Sleep(20 * time.Millisecond)

	scanner := bufio.NewScanner(clientIn)

	// Emit install:progress
	go app.emit(ProgressEvent{
		Step:    "Testing",
		Message: "Progress at 42%",
		Percent: 42.0,
		Done:    false,
	})

	if !scanner.Scan() {
		t.Fatalf("failed to read notification: %v", scanner.Err())
	}

	var notif struct {
		JSONRPC string        `json:"jsonrpc"`
		Method  string        `json:"method"`
		Params  ProgressEvent `json:"params"`
	}
	if err := json.Unmarshal(scanner.Bytes(), &notif); err != nil {
		t.Fatalf("failed to unmarshal notification: %v", err)
	}
	if notif.JSONRPC != "2.0" {
		t.Errorf("notification JSONRPC = %q, want 2.0", notif.JSONRPC)
	}
	if notif.Method != "install:progress" {
		t.Errorf("notification Method = %q, want install:progress", notif.Method)
	}
	if notif.Params.Percent != 42.0 || notif.Params.Step != "Testing" {
		t.Errorf("unexpected params: %+v", notif.Params)
	}

	// Emit vm:progress
	go app.emitVM(VMEvent{
		Stage:   "pulling",
		Percent: 99.0,
		Message: "Finishing",
	})

	if !scanner.Scan() {
		t.Fatalf("failed to read vm notification: %v", scanner.Err())
	}

	var vmNotif struct {
		JSONRPC string  `json:"jsonrpc"`
		Method  string  `json:"method"`
		Params  VMEvent `json:"params"`
	}
	if err := json.Unmarshal(scanner.Bytes(), &vmNotif); err != nil {
		t.Fatalf("failed to unmarshal vm notification: %v", err)
	}
	if vmNotif.Method != "vm:progress" {
		t.Errorf("notification Method = %q, want vm:progress", vmNotif.Method)
	}
	if vmNotif.Params.Stage != "pulling" || vmNotif.Params.Percent != 99.0 {
		t.Errorf("unexpected params: %+v", vmNotif.Params)
	}
}

func TestShutdownMethod(t *testing.T) {
	h := newPipeHarness(t)
	defer h.Close()

	res, rpcErr := h.call(t, "Shutdown", nil, 99)
	if rpcErr != nil {
		t.Fatalf("unexpected error on Shutdown: %+v", rpcErr)
	}
	if string(res) != "null" {
		t.Errorf("Shutdown result = %s, want null", string(res))
	}

	select {
	case err := <-h.serveErr:
		if err != nil {
			t.Errorf("Serve returned error after Shutdown: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Serve did not terminate after Shutdown within timeout")
	}
}

func TestStdinCloseDisarmsAndExits(t *testing.T) {
	clientIn, serverOut := io.Pipe()
	serverIn, clientOut := io.Pipe()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	app := &App{ctx: ctx}

	serveErr := make(chan error, 1)
	go func() {
		err := Serve(ctx, app, serverIn, serverOut)
		serveErr <- err
		_ = serverOut.Close()
	}()

	// Close clientOut to simulate EOF on stdin
	_ = clientOut.Close()

	select {
	case err := <-serveErr:
		if err != nil {
			t.Errorf("Serve returned error on stdin EOF: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Serve did not exit on stdin EOF within timeout")
	}
	_ = clientIn.Close()
	_ = serverIn.Close()
}

func TestInvalidMethodAndParseError(t *testing.T) {
	h := newPipeHarness(t)
	defer h.Close()

	_, rpcErr := h.call(t, "NonExistentMethod", nil, 100)
	if rpcErr == nil {
		t.Fatal("expected error for NonExistentMethod, got nil")
	}
	if rpcErr.Code != errCodeMethodNotFound {
		t.Errorf("error code = %d, want %d", rpcErr.Code, errCodeMethodNotFound)
	}

	// Send invalid JSON
	if _, err := fmt.Fprintln(h.clientOut, "{invalid json"); err != nil {
		t.Fatal(err)
	}
	if !h.scanner.Scan() {
		t.Fatal("no response for parse error")
	}
	var raw struct {
		Error *jsonrpcError `json:"error"`
	}
	if err := json.Unmarshal(h.scanner.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	if raw.Error == nil || raw.Error.Code != errCodeParseError {
		t.Errorf("expected parse error (-32700), got: %+v", raw.Error)
	}
}
