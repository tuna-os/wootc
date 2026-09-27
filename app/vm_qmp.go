package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"sync"
)

// qmpClient owns a private inherited pipe pair. There is no public listener or
// command port for another user/process to connect to.
type qmpClient struct {
	input         io.WriteCloser
	mu            sync.Mutex
	writeMu       sync.Mutex
	next          uint64
	pending       map[string]chan error
	done          chan struct{}
	greeting      chan error
	cleanShutdown bool
	err           error
}

func connectQMP(ctx context.Context, input io.WriteCloser, output io.Reader) (*qmpClient, error) {
	q := &qmpClient{input: input, pending: map[string]chan error{}, done: make(chan struct{}), greeting: make(chan error, 1)}
	go q.read(output)
	select {
	case err := <-q.greeting:
		if err != nil {
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

func (q *qmpClient) read(output io.Reader) {
	scanner := bufio.NewScanner(output)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	first := true
	var readErr error
	for scanner.Scan() {
		var packet struct {
			QMP   json.RawMessage `json:"QMP"`
			ID    string          `json:"id"`
			Event string          `json:"event"`
			Data  struct {
				Guest  bool   `json:"guest"`
				Reason string `json:"reason"`
			} `json:"data"`
			Error *struct {
				Class string `json:"class"`
				Desc  string `json:"desc"`
			} `json:"error"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &packet); err != nil {
			readErr = fmt.Errorf("invalid QMP response: %w", err)
			break
		}
		if first {
			if len(packet.QMP) == 0 {
				readErr = fmt.Errorf("QMP greeting missing")
				break
			}
			first = false
			q.greeting <- nil
			continue
		}
		q.mu.Lock()
		if packet.Event == "SHUTDOWN" && packet.Data.Guest && packet.Data.Reason == "guest-shutdown" {
			q.cleanShutdown = true
		}
		if waiter, ok := q.pending[packet.ID]; ok {
			delete(q.pending, packet.ID)
			if packet.Error != nil {
				waiter <- fmt.Errorf("QMP %s: %s", packet.Error.Class, packet.Error.Desc)
			} else {
				waiter <- nil
			}
		}
		q.mu.Unlock()
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
		waiter <- readErr
		delete(q.pending, id)
	}
	q.mu.Unlock()
	if first {
		q.greeting <- readErr
	}
	close(q.done)
}

func (q *qmpClient) command(ctx context.Context, command string) error {
	q.mu.Lock()
	if q.err != nil {
		err := q.err
		q.mu.Unlock()
		return err
	}
	q.next++
	id := strconv.FormatUint(q.next, 10)
	waiter := make(chan error, 1)
	q.pending[id] = waiter
	q.mu.Unlock()
	message, _ := json.Marshal(map[string]string{"execute": command, "id": id})
	stopCancel := context.AfterFunc(ctx, func() { _ = q.input.Close() })
	q.writeMu.Lock()
	_, err := q.input.Write(append(message, '\n'))
	q.writeMu.Unlock()
	stopCancel()
	if err != nil {
		q.mu.Lock()
		delete(q.pending, id)
		q.mu.Unlock()
		return err
	}
	select {
	case err := <-waiter:
		return err
	case <-ctx.Done():
		q.mu.Lock()
		delete(q.pending, id)
		q.mu.Unlock()
		return ctx.Err()
	}
}

func (q *qmpClient) clean() bool { q.mu.Lock(); defer q.mu.Unlock(); return q.cleanShutdown }
