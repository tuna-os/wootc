package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"
	"time"
)

type qmpResult struct {
	value json.RawMessage
	err   error
}

// qmpClient exclusively owns the inherited pipes. No public listener exists.
type qmpClient struct {
	input         io.WriteCloser
	mu            sync.Mutex
	writeGate     chan struct{}
	next          uint64
	pending       map[string]chan qmpResult
	done          chan struct{}
	greeting      chan error
	cleanShutdown bool
	err           error
}

func connectQMP(ctx context.Context, input io.WriteCloser, output io.Reader) (*qmpClient, error) {
	q := &qmpClient{input: input, writeGate: make(chan struct{}, 1), pending: map[string]chan qmpResult{}, done: make(chan struct{}), greeting: make(chan error, 1)}
	go q.read(output)
	select {
	case err := <-q.greeting:
		if err != nil {
			input.Close()
			return nil, err
		}
	case <-ctx.Done():
		input.Close()
		return nil, ctx.Err()
	}
	if err := q.command(ctx, "qmp_capabilities"); err != nil {
		input.Close()
		return nil, err
	}
	return q, nil
}

// Check duplicates recursively before decoding: encoding/json otherwise accepts
// last-wins fields, including the response identity and nested observations.
func qmpJSONValue(d *json.Decoder, depth int) error {
	if depth > 32 {
		return fmt.Errorf("QMP JSON nesting limit")
	}
	t, err := d.Token()
	if err != nil {
		return err
	}
	if delim, ok := t.(json.Delim); ok {
		switch delim {
		case '{':
			seen := map[string]bool{}
			for d.More() {
				k, e := d.Token()
				if e != nil {
					return e
				}
				key, ok := k.(string)
				if !ok || seen[strings.ToLower(key)] {
					return fmt.Errorf("duplicate QMP field")
				}
				seen[strings.ToLower(key)] = true
				if e = qmpJSONValue(d, depth+1); e != nil {
					return e
				}
			}
		case '[':
			for d.More() {
				if e := qmpJSONValue(d, depth+1); e != nil {
					return e
				}
			}
		default:
			return fmt.Errorf("unexpected QMP delimiter")
		}
		end, e := d.Token()
		if e != nil {
			return e
		}
		if (delim == '{' && end != json.Delim('}')) || (delim == '[' && end != json.Delim(']')) {
			return fmt.Errorf("invalid QMP delimiter")
		}
	}
	return nil
}
func decodeQMPObject(data []byte) (map[string]json.RawMessage, error) {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	if err := qmpJSONValue(d, 0); err != nil {
		return nil, err
	}
	if _, err := d.Token(); err != io.EOF {
		return nil, fmt.Errorf("trailing QMP JSON")
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil || fields == nil {
		return nil, fmt.Errorf("QMP object required")
	}
	return fields, nil
}
func qmpString(raw json.RawMessage) (string, error) {
	var s string
	if err := json.Unmarshal(raw, &s); err != nil || s == "" {
		return "", fmt.Errorf("QMP string required")
	}
	return s, nil
}
func (q *qmpClient) read(output io.Reader) {
	scanner := bufio.NewScanner(output)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	first := true
	var readErr error
	for scanner.Scan() {
		fields, err := decodeQMPObject(scanner.Bytes())
		if err != nil {
			readErr = err
			break
		}
		if first {
			greeting, err := decodeQMPObject(fields["QMP"])
			if err != nil || greeting["version"] == nil || greeting["capabilities"] == nil {
				readErr = fmt.Errorf("QMP greeting missing")
				break
			}
			if len(fields) != 1 {
				readErr = fmt.Errorf("ambiguous QMP greeting")
				break
			}
			first = false
			q.greeting <- nil
			continue
		}
		if event, ok := fields["event"]; ok {
			name, err := qmpString(event)
			if err != nil || fields["id"] != nil || fields["return"] != nil || fields["error"] != nil {
				readErr = fmt.Errorf("invalid QMP event")
				break
			}
			if name == "SHUTDOWN" {
				dataFields, shapeErr := decodeQMPObject(fields["data"])
				if shapeErr != nil || len(dataFields) != 2 || dataFields["guest"] == nil || dataFields["reason"] == nil {
					readErr = fmt.Errorf("invalid QMP shutdown field shape")
					break
				}
				var data struct {
					Guest  *bool  `json:"guest"`
					Reason string `json:"reason"`
				}
				if err = json.Unmarshal(fields["data"], &data); err != nil || data.Guest == nil || data.Reason == "" {
					readErr = fmt.Errorf("invalid QMP shutdown event")
					break
				}
				if *data.Guest && data.Reason == "guest-shutdown" {
					q.mu.Lock()
					q.cleanShutdown = true
					q.mu.Unlock()
				}
			}
			continue
		}
		id, err := qmpString(fields["id"])
		value, hasReturn := fields["return"]
		fault, hasError := fields["error"]
		if err != nil || hasReturn == hasError || len(fields) != 2 {
			readErr = fmt.Errorf("ambiguous QMP response")
			break
		}
		result := qmpResult{value: value}
		if hasError {
			var e struct {
				Class string `json:"class"`
				Desc  string `json:"desc"`
			}
			if err = json.Unmarshal(fault, &e); err != nil || e.Class == "" || e.Desc == "" {
				readErr = fmt.Errorf("invalid QMP error")
				break
			}
			result.err = fmt.Errorf("QMP %s: %s", e.Class, e.Desc)
		} else if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			readErr = fmt.Errorf("null QMP return")
			break
		}
		q.mu.Lock()
		waiter, ok := q.pending[id]
		if ok {
			delete(q.pending, id)
			waiter <- result
		}
		q.mu.Unlock()
		if !ok {
			readErr = fmt.Errorf("unmatched or replayed QMP response")
			break
		}
	}
	if readErr == nil {
		readErr = scanner.Err()
	}
	if readErr == nil {
		readErr = io.EOF
	}
	q.mu.Lock()
	q.err = readErr
	for id, waiter := range q.pending {
		waiter <- qmpResult{err: readErr}
		delete(q.pending, id)
	}
	q.mu.Unlock()
	if first {
		q.greeting <- readErr
	}
	close(q.done)
}

func (q *qmpClient) request(ctx context.Context, command string, args any) (json.RawMessage, error) {
	switch command {
	case "qmp_capabilities", "system_powerdown", "query-status", "query-mice", "screendump", "input-send-event":
	default:
		return nil, fmt.Errorf("unsupported engine QMP operation")
	}
	// All internal operations, including existing shutdown, have a bounded call.
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	q.mu.Lock()
	if q.err != nil {
		err := q.err
		q.mu.Unlock()
		return nil, err
	}
	q.next++
	id := strconv.FormatUint(q.next, 10)
	waiter := make(chan qmpResult, 1)
	q.pending[id] = waiter
	q.mu.Unlock()
	defer func() { q.mu.Lock(); delete(q.pending, id); q.mu.Unlock() }()
	message := map[string]any{"execute": command, "id": id}
	if args != nil {
		message["arguments"] = args
	}
	data, err := json.Marshal(message)
	if err != nil {
		return nil, err
	}
	select {
	case q.writeGate <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	if err = ctx.Err(); err != nil {
		<-q.writeGate
		return nil, err
	}
	stopCancel := context.AfterFunc(ctx, func() { _ = q.input.Close() })
	n, err := q.input.Write(append(data, '\n'))
	stopCancel()
	<-q.writeGate
	if err != nil {
		return nil, err
	}
	if n != len(data)+1 {
		return nil, io.ErrShortWrite
	}
	select {
	case result := <-waiter:
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		return result.value, result.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
func (q *qmpClient) command(ctx context.Context, command string) error {
	value, err := q.request(ctx, command, nil)
	if err != nil {
		return err
	}
	obj, err := decodeQMPObject(value)
	if err != nil || len(obj) != 0 {
		return fmt.Errorf("QMP command requires empty object acknowledgment")
	}
	return nil
}
func (q *qmpClient) clean() bool { q.mu.Lock(); defer q.mu.Unlock(); return q.cleanShutdown }
