package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"
)

func TestQMPTypedResponseCounterexamples(t *testing.T) {
	for _, body := range []string{`{"id":"2"}`, `{"return":null,"id":"2"}`, `{"return":{},"error":{"class":"GenericError","desc":"failed"},"id":"2"}`, `{"return":{},"id":"2","id":"2"}`, `{"return":{"running":true,"running":false},"id":"2"}`, `{"return":{},"id":"unknown"}`, `{"error":{"class":"GenericError","desc":"failed"},"id":"2"}`} {
		t.Run(body, func(t *testing.T) {
			childIn, parentIn := io.Pipe()
			parentOut, childOut := io.Pipe()
			defer parentIn.Close()
			defer childOut.Close()
			defer parentOut.Close()
			defer childIn.Close()
			go func() {
				fmt.Fprintln(childOut, `{"QMP":{"version":{},"capabilities":[]}}`)
				r := bufio.NewScanner(childIn)
				if r.Scan() {
					fmt.Fprintln(childOut, `{"return":{},"id":"1"}`)
				}
				if r.Scan() {
					fmt.Fprintln(childOut, body)
				}
			}()
			ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
			defer cancel()
			q, err := connectQMP(ctx, parentIn, parentOut)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = q.request(ctx, "query-status", nil); err == nil {
				t.Fatal("invalid response accepted")
			}
		})
	}
}
func TestQMPBoundedBlockedWriteAndUnsupportedCommand(t *testing.T) {
	childIn, parentIn := io.Pipe()
	parentOut, childOut := io.Pipe()
	defer childIn.Close()
	defer parentIn.Close()
	defer childOut.Close()
	defer parentOut.Close()
	go fmt.Fprintln(childOut, `{"QMP":{"version":{},"capabilities":[]}}`)
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := connectQMP(ctx, parentIn, parentOut); err == nil {
		t.Fatal("blocked write accepted")
	}
	if time.Since(start) > 500*time.Millisecond {
		t.Fatal("blocked write exceeded bound")
	}
	q := &qmpClient{}
	if _, err := q.request(context.Background(), "human-monitor-command", nil); err == nil {
		t.Fatal("arbitrary QMP accepted")
	}
}
func TestQMPDuplicateOrMalformedJSON(t *testing.T) {
	for _, body := range []string{`{"return":{"x":1,"x":2}}`, `{"a":1} {"b":2}`, `null`, `[]`, strings.Repeat("[", 34) + strings.Repeat("]", 34)} {
		if _, err := decodeQMPObject([]byte(body)); err == nil {
			t.Fatal("ambiguous JSON accepted", body)
		}
	}
}

func TestQMPShutdownNeedsLiteralTypedFields(t *testing.T) {
	for _, data := range []string{`{"Guest":true,"reason":"guest-shutdown"}`, `{"guest":true,"Reason":"guest-shutdown"}`, `{"guest":"true","reason":"guest-shutdown"}`, `{"guest":true,"reason":"guest-shutdown","reason":"host-qmp-quit"}`} {
		q := &qmpClient{pending: map[string]chan qmpResult{}, done: make(chan struct{}), greeting: make(chan error, 1)}
		q.read(strings.NewReader(`{"QMP":{"version":{},"capabilities":[]}}` + "\n" + `{"event":"SHUTDOWN","data":` + data + "}\n"))
		if q.clean() {
			t.Fatal("malformed shutdown became clean guest stop", data)
		}
	}
}
